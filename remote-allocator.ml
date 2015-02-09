open Lwt
open Sexplib.Std
open Block_ring_unix
open Log

module Config = struct
  type host = {
    to_lvm: string; (* where to read changes to be written to LVM from *)
    from_lvm: string; (* where to write changes from LVM to *)
    free: string; (* name of the free block LV *)
  } with sexp

  type t = {
    host_allocation_quantum: int64; (* amount of allocate each host at a time (MiB) *)
    host_low_water_mark: int64; (* when the free memory drops below, we allocate (MiB) *)
    vg: string; (* name of the volume group *)
    device: string; (* physical device containing the volume group *)
    hosts: (string * host) list; (* host id -> rings *)
    master_journal: string; (* path to the SRmaster journal *)
  } with sexp
end

module ToLVM = Block_queue.Popper(ExpandVolume)
module FromLVM = Block_queue.Pusher(FreeAllocation)

module Op = struct
  module T = struct
    type host = string with sexp
    type t =
      | Print of string
      | BatchOfAllocations of (host * ExpandVolume.t) list (* from the host *)
      | FreeAllocation of (host * FreeAllocation.t) (* to a host *)
    with sexp
  end

  include SexpToCstruct.Make(T)
  include T
end

let (>>|=) m f = m >>= function
  | `Error e -> fail (Failure e)
  | `Ok x -> f x

let main socket config =
  let config = Config.t_of_sexp (Sexplib.Sexp.load_sexp config) in
  debug "Loaded configuration: %s" (Sexplib.Sexp.to_string_hum (Config.sexp_of_t config));
  let t =
    Device.read_sector_size config.Config.device
    >>= fun sector_size ->

    let to_LVMs = List.map (fun (host, { Config.to_lvm }) ->
      host, ToLVM.start to_lvm
    ) config.Config.hosts in

    Lwt_list.map_s (fun (host, { Config.from_lvm }) ->
      FromLVM.start from_lvm
      >>= fun from_lvm ->
      return (host, from_lvm)
    ) config.Config.hosts
    >>= fun from_LVMs ->

    let update_vg f =
      let module Disk = Disk_mirage.Make(Block)(Io_page) in
      let module Vg_IO = Lvm.Vg.Make(Disk) in
      Vg_IO.read [ config.Config.device ] >>|= fun vg ->
      f vg >>|= fun vg ->
      Vg_IO.write vg >>|= fun _ ->
      return () in

    let update_lv (vg: Lvm.Vg.t) name f =
      let open Lvm.Result in
      match List.partition (fun lv -> lv.Lvm.Lv.name = name) vg.Lvm.Vg.lvs with
      | [ lv ], others ->
        f lv
        >>= fun lv' ->
        (* NB this doesn't update free space *)
        return { vg with Lvm.Vg.lvs = lv' :: others }
      | _, _ -> `Error (Printf.sprintf "Failed to isolate LV with name %s" name) in

    let perform t =
      let open Op in
      sexp_of_t t |> Sexplib.Sexp.to_string_hum |> print_endline;
      match t with
      | Print _ -> return ()
      | BatchOfAllocations expands ->
        update_vg
          (fun vg ->
            let expand (vg: Lvm.Vg.t) (host, { ExpandVolume.volume; segments }) : Lvm.Vg.t =
              let open Lvm.Result in
              (* expand the data volume with the segments *)
debug "Expanding LV";
              let vg, _ =
                Lvm.Vg.do_op vg (Lvm.Redo.Op.(LvExpand(volume, { lvex_segments = segments }))
                |> ok_or_failwith in
(*
              let vg = update_lv (vg: Lvm.Vg.t) volume
                (fun lv ->
                  let open Lvm in
                  let segments =
                     Lv.Segment.sort (segments @ lv.Lv.segments)
                  |> List.fold_left (fun (last_start, acc) segment ->
                     (* Check if the segments are identical *)
                     if segment.Lv.Segment.start_extent = last_start
                     then last_start, acc
                     else segment.Lv.Segment.start_extent, segment :: acc
                     ) (-1L, [])
                  |> snd
                  |> List.rev in
                  return  { lv with segments }
                ) |> ok_or_failwith in
*)
debug "OK";
              let free = (List.assoc host config.Config.hosts).Config.free in
              (* remove the segments from the free volume *)
              update_lv (vg: Lvm.Vg.t) free
                (fun lv ->
                  let current = Lvm.Lv.to_allocation lv in
debug "Free LV has: %s" (Sexplib.Sexp.to_string_hum (Lvm.Pv.Allocator.sexp_of_t current));
                  let allocated = List.fold_left Lvm.Pv.Allocator.merge [] (List.map Lvm.Lv.Segment.to_allocation segments) in
debug "Just allocated: %s" (Sexplib.Sexp.to_string_hum (Lvm.Pv.Allocator.sexp_of_t allocated));

                  let reduced = Lvm.Pv.Allocator.sub current allocated in
debug "Free LV will have: %s" (Sexplib.Sexp.to_string_hum (Lvm.Pv.Allocator.sexp_of_t reduced));

                  let segments = Lvm.Lv.Segment.linear 0L reduced in
                  return { lv with Lvm.Lv.segments }
                ) |> ok_or_failwith in
            return (`Ok (List.fold_left expand vg expands))
          )
      | FreeAllocation (host, allocation) ->
        let q = try Some(List.assoc host from_LVMs) with Not_found -> None in
        let host' = try Some(List.assoc host config.Config.hosts) with Not_found -> None in
        begin match q, host' with
        | Some from_lvm, Some { free }  ->
          update_vg
            (fun vg ->
               match List.partition (fun lv -> lv.Lvm.Lv.name=free) vg.lvs with
               | [ lv ], others ->
                 let size = Lvm.Lv.size_in_extents lv in
                 let segments = Lvm.Lv.Segment.linear size allocation in
                 begin match Lvm.Vg.do_op vg (Lvm.Redo.Op.(LvExpand(free, { lvex_segments = segments }))) with
                 | `Ok (vg, _) -> return (`Ok vg)
                 | `Error x -> return (`Error x)
                 end
               | _, _ ->
                 return (`Error (Printf.sprintf "Failed to find volume %s" free))
            )
          >>= fun () ->
          FromLVM.push from_lvm allocation
          >>= fun pos ->
          FromLVM.advance from_lvm pos
        | _, _ ->
          info "unable to push block update to host %s because it has disappeared" host;
          return () 
        end in

    let module J = Shared_block.Journal.Make(Block_ring_unix.Producer)(Block_ring_unix.Consumer)(Op) in
    J.start config.Config.master_journal perform
    >>= fun j ->

    let top_up_free_volumes () =
      let module Disk = Disk_mirage.Make(Block)(Io_page) in
      let module Vg_IO = Lvm.Vg.Make(Disk) in
      Vg_IO.read [ config.Config.device ]
      >>= function
      | `Error e ->
        error "Ignoring error reading LVM metadata: %s" e;
        return ()
      | `Ok x ->
        let extent_size = x.Lvm.Vg.extent_size in (* in sectors *)
        let extent_size_mib = Int64.(div (mul extent_size (of_int sector_size)) (mul 1024L 1024L)) in
        (* XXX: avoid double-allocating the same free blocks *)
        Lwt_list.iter_s
         (fun (host, { Config.free }) ->
           match try Some(List.find (fun lv -> lv.Lvm.Lv.name = free) x.Lvm.Vg.lvs) with _ -> None with
           | Some lv ->
             let size_mib = Int64.mul (Lvm.Lv.size_in_extents lv) extent_size_mib in
             if size_mib < config.Config.host_low_water_mark then begin
               Printf.printf "LV %s is %Ld MiB < low_water_mark %Ld MiB; allocating %Ld MiB\n%!" free size_mib config.Config.host_low_water_mark config.Config.host_allocation_quantum;
               (* find free space in the VG *)
               begin match Lvm.Pv.Allocator.find x.Lvm.Vg.free_space Int64.(div config.Config.host_allocation_quantum extent_size_mib) with
               | `Error free_extents ->
                 info "LV %s is %Ld MiB but total space free (%Ld MiB) is less than allocation quantum (%Ld MiB)"
                   free size_mib Int64.(mul free_extents extent_size_mib) config.Config.host_allocation_quantum;
                 (* try again later *)
                 return ()
               | `Ok allocated_extents ->
                 J.push j (Op.FreeAllocation (host, allocated_extents))
               end
             end else return ()
           | None ->
             error "Failed to find host %s free LV %s" host free;
             return ()
         ) config.Config.hosts in

    let rec main_loop () =
      (* 1. Do any of the host free LVs need topping up? *)
      top_up_free_volumes ()
      >>= fun () ->

      (* 2. Are there any pending LVM updates from hosts? *)
      Lwt_list.map_p
        (fun (host, t) ->
          t >>= fun to_lvm ->
          ToLVM.pop to_lvm
          >>= fun (pos, item) ->
          return (host, to_lvm, pos, item)
        ) to_LVMs
      >>= fun work ->
      let items = List.concat (List.map (fun (_, _, _, bu) -> bu) work) in
      if items = [] then begin
        debug "sleeping for 5s";
        Lwt_unix.sleep 5.
        >>= fun () ->
        main_loop ()
      end else begin
        J.push j (Op.BatchOfAllocations (List.concat (List.map (fun (host, _, _, bu) -> List.map (fun x -> host, x) bu) work)))
        >>= fun () -> 
        (* write the work to a journal *)
        Lwt_list.iter_p
          (fun (_, t, pos, _) ->
            ToLVM.advance t pos
          ) work
        >>= fun () ->
        main_loop ()
      end in
    main_loop () in
  try
    `Ok (Lwt_main.run t)
  with Failure msg ->
    error "%s" msg;
    `Error(false, msg)

open Cmdliner
let info =
  let doc =
    "Remote block allocator" in
  let man = [
    `S "EXAMPLES";
    `P "TODO";
  ] in
  Term.info "remote-allocator" ~version:"0.1-alpha" ~doc ~man

let socket =
  let doc = "Path of Unix domain socket to listen on" in
  Arg.(value & opt (some string) None & info [ "socket" ] ~docv:"SOCKET" ~doc)

let config =
  let doc = "Path to the config file" in
  Arg.(value & opt file "remoteConfig" & info [ "config" ] ~docv:"CONFIG" ~doc)

let () =
  let t = Term.(pure main $ socket $ config) in
  match Term.eval (t, info) with
  | `Error _ -> exit 1
  | _ -> exit 0
