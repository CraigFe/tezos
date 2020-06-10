(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2020 Nomadic Labs. <nomadic@tezcore.com>               *)
(* Copyright (c) 2018-2020 Tarides <contact@tarides.com>                     *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

let current_version = "tezos-snapshot-1.0.0"

[@@@ocaml.warning "-26"]
[@@@ocaml.warning "-32"]

(*****************************************************************************)
module type Dump_interface = sig
  type index

  type context

  type tree

  type hash

  type step = string

  type key = step list

  type commit_info

  type batch

  val batch : index -> (batch -> 'a Lwt.t) -> 'a Lwt.t

  val commit_info_encoding : commit_info Data_encoding.t

  val hash_encoding : hash Data_encoding.t

  module Block_header : sig
    type t = Block_header.t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val equal : t -> t -> bool

    val encoding : t Data_encoding.t
  end

  module Pruned_block : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val header : t -> Block_header.t

    val encoding : t Data_encoding.t
  end

  module Block_data : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val header : t -> Block_header.t

    val encoding : t Data_encoding.t
  end

  module Protocol_data : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val encoding : t Data_encoding.t
  end

  module Commit_hash : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t tzresult

    val encoding : t Data_encoding.t
  end

  (* commit manipulation (for parents) *)
  val context_parents : context -> Commit_hash.t list

  (* Commit info *)
  val context_info : context -> commit_info

  (* block header manipulation *)
  val get_context : index -> Block_header.t -> context option Lwt.t

  val set_context :
    info:commit_info ->
    parents:Commit_hash.t list ->
    context ->
    Block_header.t ->
    Block_header.t option Lwt.t

  (* for dumping *)
  val context_tree : context -> tree

  val tree_hash : tree -> hash

  val sub_tree : tree -> key -> tree option Lwt.t

  val tree_list : tree -> (step * [`Contents | `Node]) list Lwt.t

  val tree_content : tree -> string option Lwt.t

  (* for restoring *)
  val make_context : index -> context

  val update_context : context -> tree -> context

  val add_string : batch -> string -> tree Lwt.t

  val add_dir : batch -> (step * hash) list -> tree option Lwt.t
end

module type S = sig
  type index

  type context

  type block_header

  type block_data

  type pruned_block

  type protocol_data

  val dump_contexts_fd :
    index ->
    block_header
    * block_data
    * History_mode.t
    * (block_header ->
      (pruned_block option * protocol_data option) tzresult Lwt.t) ->
    fd:Lwt_unix.file_descr ->
    unit tzresult Lwt.t

  val restore_contexts_fd :
    index ->
    fd:Lwt_unix.file_descr ->
    ((Block_hash.t * pruned_block) list -> unit tzresult Lwt.t) ->
    (block_header option ->
    Block_hash.t ->
    pruned_block ->
    unit tzresult Lwt.t) ->
    ( block_header
    * block_data
    * History_mode.t
    * Block_header.t option
    * Block_hash.t list
    * protocol_data list )
    tzresult
    Lwt.t
end

type error += System_write_error of string

type error += Bad_hash of string * Bytes.t * Bytes.t

type error += Context_not_found of Bytes.t

type error += System_read_error of string

type error += Inconsistent_snapshot_file

type error += Inconsistent_snapshot_data

type error += Missing_snapshot_data

type error += Invalid_snapshot_version of string * string

type error += Restore_context_failure

let () =
  let open Data_encoding in
  register_error_kind
    `Permanent
    ~id:"Writing_error"
    ~title:"Writing error"
    ~description:"Cannot write in file for context dump"
    ~pp:(fun ppf s ->
      Format.fprintf ppf "Unable to write file for context dumping: %s" s)
    (obj1 (req "context_dump_no_space" string))
    (function System_write_error s -> Some s | _ -> None)
    (fun s -> System_write_error s) ;
  register_error_kind
    `Permanent
    ~id:"Bad_hash"
    ~title:"Bad hash"
    ~description:"Wrong hash given"
    ~pp:(fun ppf (ty, his, hshould) ->
      Format.fprintf
        ppf
        "Wrong hash [%s] given: %s, should be %s"
        ty
        (Bytes.to_string his)
        (Bytes.to_string hshould))
    (obj3
       (req "hash_ty" string)
       (req "hash_is" bytes)
       (req "hash_should" bytes))
    (function
      | Bad_hash (ty, his, hshould) -> Some (ty, his, hshould) | _ -> None)
    (fun (ty, his, hshould) -> Bad_hash (ty, his, hshould)) ;
  register_error_kind
    `Permanent
    ~id:"Context_not_found"
    ~title:"Context not found"
    ~description:"Cannot find context corresponding to hash"
    ~pp:(fun ppf mb ->
      Format.fprintf ppf "No context with hash: %s" (Bytes.to_string mb))
    (obj1 (req "context_not_found" bytes))
    (function Context_not_found mb -> Some mb | _ -> None)
    (fun mb -> Context_not_found mb) ;
  register_error_kind
    `Permanent
    ~id:"System_read_error"
    ~title:"System read error"
    ~description:"Failed to read file"
    ~pp:(fun ppf uerr ->
      Format.fprintf
        ppf
        "Error while reading file for context dumping: %s"
        uerr)
    (obj1 (req "system_read_error" string))
    (function System_read_error e -> Some e | _ -> None)
    (fun e -> System_read_error e) ;
  register_error_kind
    `Permanent
    ~id:"Inconsistent_snapshot_file"
    ~title:"Inconsistent snapshot file"
    ~description:"Error while opening snapshot file"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Failed to read snapshot file. The provided file is inconsistent.")
    empty
    (function Inconsistent_snapshot_file -> Some () | _ -> None)
    (fun () -> Inconsistent_snapshot_file) ;
  register_error_kind
    `Permanent
    ~id:"Inconsistent_snapshot_data"
    ~title:"Inconsistent snapshot data"
    ~description:"The data provided by the snapshot is inconsistent"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "The data provided by the snapshot file is inconsistent (context_hash \
         does not correspond for block).")
    empty
    (function Inconsistent_snapshot_data -> Some () | _ -> None)
    (fun () -> Inconsistent_snapshot_data) ;
  register_error_kind
    `Permanent
    ~id:"Missing_snapshot_data"
    ~title:"Missing data in imported snapshot"
    ~description:"Mandatory data missing while reaching end of snapshot file."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Mandatory data is missing is the provided snapshot file.")
    empty
    (function Missing_snapshot_data -> Some () | _ -> None)
    (fun () -> Missing_snapshot_data) ;
  register_error_kind
    `Permanent
    ~id:"Invalid_snapshot_version"
    ~title:"Invalid snapshot version"
    ~description:"The version of the snapshot to import is not valid"
    ~pp:(fun ppf (found, expected) ->
      Format.fprintf
        ppf
        "The snapshot to import has version \"%s\" but \"%s\" was expected."
        found
        expected)
    (obj2 (req "found" string) (req "expected" string))
    (function
      | Invalid_snapshot_version (found, expected) ->
          Some (found, expected)
      | _ ->
          None)
    (fun (found, expected) -> Invalid_snapshot_version (found, expected)) ;
  register_error_kind
    `Permanent
    ~id:"Restore_context_failure"
    ~title:"Failed to restore context"
    ~description:"Internal error while restoring the context"
    ~pp:(fun ppf () ->
      Format.fprintf ppf "Internal error while restoring the context.")
    empty
    (function Restore_context_failure -> Some () | _ -> None)
    (fun () -> Restore_context_failure)

module Make (I : Dump_interface) = struct
  type command =
    | Root of {
        block_header : I.Block_header.t;
        info : I.commit_info;
        parents : I.Commit_hash.t list;
        block_data : I.Block_data.t;
      }
    | Node of (string * I.hash) list
    | Blob of string
    | Proot of I.Pruned_block.t
    | Loot of I.Protocol_data.t
    | End

  (* Command encoding. *)

  let blob_encoding =
    let open Data_encoding in
    case
      ~title:"blob"
      (Tag (Char.code 'b'))
      string
      (function Blob string -> Some string | _ -> None)
      (function string -> Blob string)

  let node_encoding =
    let open Data_encoding in
    case
      ~title:"node"
      (Tag (Char.code 'd'))
      (list (obj2 (req "name" string) (req "hash" I.hash_encoding)))
      (function Node x -> Some x | _ -> None)
      (function x -> Node x)

  let end_encoding =
    let open Data_encoding in
    case
      ~title:"end"
      (Tag (Char.code 'e'))
      empty
      (function End -> Some () | _ -> None)
      (fun () -> End)

  let loot_encoding =
    let open Data_encoding in
    case
      ~title:"loot"
      (Tag (Char.code 'l'))
      I.Protocol_data.encoding
      (function Loot protocol_data -> Some protocol_data | _ -> None)
      (fun protocol_data -> Loot protocol_data)

  let proot_encoding =
    let open Data_encoding in
    case
      ~title:"proot"
      (Tag (Char.code 'p'))
      (obj1 (req "pruned_block" I.Pruned_block.encoding))
      (function Proot pruned_block -> Some pruned_block | _ -> None)
      (fun pruned_block -> Proot pruned_block)

  let root_encoding =
    let open Data_encoding in
    case
      ~title:"root"
      (Tag (Char.code 'r'))
      (obj4
         (req "block_header" (dynamic_size I.Block_header.encoding))
         (req "info" I.commit_info_encoding)
         (req "parents" (list I.Commit_hash.encoding))
         (req "block_data" I.Block_data.encoding))
      (function
        | Root {block_header; info; parents; block_data} ->
            Some (block_header, info, parents, block_data)
        | _ ->
            None)
      (fun (block_header, info, parents, block_data) ->
        Root {block_header; info; parents; block_data})

  let command_encoding =
    Data_encoding.union
      ~tag_size:`Uint8
      [ blob_encoding;
        node_encoding;
        end_encoding;
        loot_encoding;
        proot_encoding;
        root_encoding ]

  (* IO toolkit. *)

  let rec read_string rbuf ~len =
    let (fd, buf, ofs, total) = !rbuf in
    if Bytes.length buf - ofs < len then (
      let blen = Bytes.length buf - ofs in
      let neu = Bytes.create (blen + 1_000_000) in
      Bytes.blit buf ofs neu 0 blen ;
      Lwt_unix.read fd neu blen 1_000_000
      >>= fun bread ->
      total := !total + bread ;
      if bread = 0 then fail Inconsistent_snapshot_file
      else
        let neu =
          if bread <> 1_000_000 then Bytes.sub neu 0 (blen + bread) else neu
        in
        rbuf := (fd, neu, 0, total) ;
        read_string rbuf ~len )
    else
      let res = Bytes.sub_string buf ofs len in
      rbuf := (fd, buf, ofs + len, total) ;
      return res

  let read_mbytes rbuf b =
    read_string rbuf ~len:(Bytes.length b)
    >>=? fun string ->
    Bytes.blit_string string 0 b 0 (Bytes.length b) ;
    return ()

  let set_int64 buf i =
    let b = Bytes.create 8 in
    EndianBytes.BigEndian.set_int64 b 0 i ;
    Buffer.add_bytes buf b

  let get_int64 rbuf =
    read_string ~len:8 rbuf
    >>=? fun s -> return @@ EndianString.BigEndian.get_int64 s 0

  let set_mbytes buf b =
    set_int64 buf (Int64.of_int (Bytes.length b)) ;
    Buffer.add_bytes buf b

  let get_mbytes rbuf =
    get_int64 rbuf >>|? Int64.to_int
    >>=? fun l ->
    let b = Bytes.create l in
    read_mbytes rbuf b >>=? fun () -> return b

  (* Getter and setters *)

  let get_command rbuf =
    get_mbytes rbuf
    >>|? fun bytes -> Data_encoding.Binary.of_bytes_exn command_encoding bytes

  let set_root buf block_header info parents block_data =
    let root = Root {block_header; info; parents; block_data} in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding root in
    set_mbytes buf bytes

  let set_node buf contents =
    let bytes =
      Data_encoding.Binary.to_bytes_exn command_encoding (Node contents)
    in
    set_mbytes buf bytes

  let set_blob buf data =
    let bytes =
      Data_encoding.Binary.to_bytes_exn command_encoding (Blob data)
    in
    set_mbytes buf bytes

  let set_proot buf pruned_block =
    let proot = Proot pruned_block in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding proot in
    set_mbytes buf bytes

  let set_loot buf protocol_data =
    let loot = Loot protocol_data in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding loot in
    set_mbytes buf bytes

  let set_end buf =
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding End in
    set_mbytes buf bytes

  (* Snapshot metadata *)

  (* TODO add more info (e.g. nb context item, nb blocks, etc.) *)
  type snapshot_metadata = {
    version : string;
    mode : Tezos_shell_services.History_mode.t;
  }

  let snapshot_metadata_encoding =
    let open Data_encoding in
    conv
      (fun {version; mode} -> (version, mode))
      (fun (version, mode) -> {version; mode})
      (obj2
         (req "version" string)
         (req "mode" Tezos_shell_services.History_mode.encoding))

  let write_snapshot_metadata ~mode buf =
    let version = {version = current_version; mode} in
    let bytes =
      Data_encoding.(Binary.to_bytes_exn snapshot_metadata_encoding version)
    in
    set_mbytes buf bytes

  let read_snapshot_metadata rbuf =
    get_mbytes rbuf
    >>|? fun bytes ->
    Data_encoding.(Binary.of_bytes_exn snapshot_metadata_encoding) bytes

  let check_version v =
    fail_when
      (v.version <> current_version)
      (Invalid_snapshot_version (v.version, current_version))

  module Memprof = struct
    [@@@ocaml.warning "-32"]

    [@@@ocaml.warning "-37"]

    type alloc_kind = Minor | Major | Unmarshalled

    type sample_info = {
      n_samples : int;
      kind : alloc_kind;
      tag : int;
      size : int;
      callstack : Printexc.raw_backtrace;
    }

    type 'a callback = sample_info -> (Obj.t, 'a) Ephemeron.K1.t option

    type 'a ctrl = {
      sampling_rate : float;
      callstack_size : int;
      callback : 'a callback;
    }

    let stopped_ctrl =
      {
        sampling_rate = 0.;
        callstack_size = 0;
        callback = (fun _ -> assert false);
      }

    external set_ctrl : 'a ctrl -> unit = "caml_memprof_set"

    let start = set_ctrl

    let stop () = set_ctrl stopped_ctrl
  end

  type location = [%import: Printexc.location] [@@deriving ord]

  module Map = Map.Make (struct
    type t = location array [@@deriving ord]
  end)

  let debug = false

  let shape : ((int * int), int) Hashtbl.t = Hashtbl.create 0

  let heap_log, statmemprof_log, shape_log =
    Random.self_init ();
    let uid = Random.int64 Int64.max_int in
    let tmp_dir = Fmt.str "/tmp/stats-%Ld" uid in
    let statfmt name = (tmp_dir ^ "/" ^ name) |> open_out |> Format.formatter_of_out_channel in

    Unix.mkdir tmp_dir 0o755;
    let heap = statfmt "heap" and statmemprof = statfmt "statmemprof" in

    Fmt.pf heap "total visited,minor words,major words\n";
    Fmt.pr "Stats streaming to `%s'\n%!" tmp_dir;
    (heap, statmemprof, statfmt "shape")

  let tbl = ref Map.empty
  let memprof_active = ref false

  let dump_tbl () =
    if debug then
      Map.bindings !tbl
      |> List.sort (fun (_, (i, _)) (_, (j, _)) -> -Int.compare i j)
      |> List.take_n 20
      |> List.iter (fun (trace, (size_total, count)) ->
            let pp_loc ppf
                Printexc.{filename; line_number; start_char; end_char} =
              Fmt.pf
                ppf
                "%s:%d (cols %d-%d)"
                filename
                line_number
                start_char
                end_char
            in
            Fmt.pf statmemprof_log
              "%d       @[<v>Average size: %f@,@,%a@]\n\n%!"
              count
              (Float.of_int size_total /. Float.of_int count)
              Fmt.(array ~sep:cut pp_loc)
              trace)

  let () =
    let callback info =
      let open Memprof in
      let () =
        if !memprof_active then
          match (info.kind, Printexc.backtrace_slots info.callstack) with
          | (_, None) | ((Major | Unmarshalled), _) ->
            ()
          | (Minor, Some slots) ->
            slots |> Array.to_list
            |> List.filter_map Printexc.Slot.location
            |> fun locs ->
            tbl :=
              Map.update
                (Array.of_list locs)
                (function
                  | Some (tot, i) -> Some (tot + info.size, i + 1)
                  | None -> Some (info.size, 1))
                !tbl
      in
      None
    in
    if debug then
      Memprof.(start {sampling_rate = 0.001; callstack_size = 50; callback})

  let print_state () =
    dump_tbl () ;
    Fmt.pf shape_log "count,depth,width\n";
    Hashtbl.to_seq shape |> Seq.iter (fun ((depth, height), count) -> Fmt.pf shape_log "%d,%d,%d\n" count depth height);
    ()

  (* Folding through a node *)
  let fold_tree_path ~(written : int ref) ~(maybe_flush : unit -> unit Lwt.t)
      ~buf ctxt tree =
    (* Noting the visited hashes *)
    let visited_hash = Hashtbl.create 1000 in
    let visited h = Hashtbl.mem visited_hash h in
    let set_visit =
      let total_visited = ref 0 in
      fun h ->
        if !total_visited mod 1_000 = 0 then (
          let Gc.{major_words; minor_words; _} = Gc.quick_stat () in
          Fmt.pf heap_log "%d,%f,%f\n%!" !total_visited minor_words major_words ;
          if !total_visited = 3_000_000 then memprof_active := true ;
          Tezos_stdlib_unix.Utils.display_progress
            ~refresh_rate:(!total_visited, 1_000)
            (fun m ->
              m
                "Context: %dK elements, %dMiB written%!"
                (!total_visited / 1_000)
                (!written / 1_048_576)) ) ;
        incr total_visited ;
        Hashtbl.add visited_hash h () ;
        ()
    in
    let cpt = ref 0 in
    let rec fold_tree_path ctxt tree =
      I.tree_list tree
      >>= fun keys ->
      let keys = List.sort (fun (a, _) (b, _) -> String.compare a b) keys in
      Lwt_list.map_s
        (fun (name, kind) ->
          I.sub_tree tree [name]
          >>= function
          | None ->
              assert false
          | Some sub_tree ->
              let hash = I.tree_hash sub_tree in
              ( if visited hash then Lwt.return_unit
              else (
                Tezos_stdlib_unix.Utils.display_progress
                  ~refresh_rate:(!cpt, 1_000)
                  (fun m ->
                    m
                      "Context: %dK elements, %dMiB written%!"
                      (!cpt / 1_000)
                      (!written / 1_048_576)) ;
                incr cpt ;
                set_visit hash ;
                (* There cannot be a cycle *)
                match kind with
                | `Node ->
                    fold_tree_path ctxt sub_tree
                | `Contents -> (
                    I.tree_content sub_tree
                    >>= function
                    | None ->
                        assert false
                    | Some data ->
                        set_blob buf data ; maybe_flush () ) ) )
              >|= fun () -> (name, hash))
        keys
      >>= fun sub_keys -> set_node buf sub_keys ; maybe_flush ()
    in
    fold_tree_path ctxt tree

  let cons_option hd_opt tl =
    match hd_opt with Some x -> x :: tl | None -> tl

  let dump_contexts_fd idx data ~fd =
    (* Dumping *)
    let buf = Buffer.create 1_000_000 in
    let written = ref 0 in
    let flush () =
      let contents = Buffer.contents buf in
      Buffer.reset buf ;
      written := !written + String.length contents ;
      Lwt_utils_unix.write_string fd contents
    in
    let maybe_flush () =
      if (* true *) Buffer.length buf > 1_000_000 then flush ()
      else Lwt.return_unit
    in
    Lwt.catch
      (fun () ->
        let (bh, _block_data, mode, _pruned_iterator) = data in
        write_snapshot_metadata ~mode buf ;
        I.get_context idx bh
        >>= function
        | None ->
            fail @@ Context_not_found (I.Block_header.to_bytes bh)
        | Some ctxt ->
            let tree = I.context_tree ctxt in
            fold_tree_path ~written ~maybe_flush ~buf ctxt tree
            >>= fun () ->
            Tezos_stdlib_unix.Utils.display_progress_end () ;
            (* written := 0;
             * let parents = I.context_parents ctxt in
             * set_root buf bh (I.context_info ctxt) parents block_data ;
             * (\* Dump pruned blocks *\)
             * let dump_pruned =
             *   let counter = ref 0 in
             *   fun pruned ->
             *     incr counter ;
             *     Tezos_stdlib_unix.Utils.display_progress
             *       ~refresh_rate:(!counter, 1_000)
             *       (fun m ->
             *         m
             *           "History: %dK block, %dMiB written"
             *           (!counter / 1_000)
             *           (!written / 1_048_576)) ;
             *     set_proot buf pruned ;
             *     maybe_flush ()
             * in
             * let rec aux acc header =
             *   pruned_iterator header
             *   >>=? fun (pred_opt, pdata) ->
             *   let acc = cons_option pdata acc in
             *   match pred_opt with
             *   | None -> return acc
             *   | Some pred_pruned ->
             *     dump_pruned pred_pruned
             *       >>= fun () ->
             *       (aux [@ocaml.tailcall]) acc (I.Pruned_block.header pred_pruned)
             * in
             * let starting_block_header = I.Block_data.header block_data in
             * aux [] starting_block_header
             * >>=? fun protocol_datas ->
             * (\* Dump protocol data *\)
             * Lwt_list.iter_s
             *   (fun proto -> set_loot buf proto ; maybe_flush ())
             *   protocol_datas
             * >>= fun () ->
             * Tezos_stdlib_unix.Utils.display_progress_end () ;
             * return_unit
             * >>=? fun () ->
             * set_end buf ; *)
            flush () >>= fun () -> print_state () ; return_unit)
      (function
        | Unix.Unix_error (e, _, _) ->
            fail @@ System_write_error (Unix.error_message e)
        | err ->
            Lwt.fail err)

  (* Restoring *)

  let restore_contexts_fd index ~fd k_store_pruned_blocks block_validation =
    let read = ref 0 in
    let rbuf = ref (fd, Bytes.empty, 0, read) in
    (* Editing the repository *)
    let add_blob t blob = I.add_string t blob >>= fun tree -> return tree in
    let add_dir t keys =
      I.add_dir t keys
      >>= function
      | None -> fail Restore_context_failure | Some tree -> return tree
    in
    let restore history_mode =
      let rec first_pass batch ctxt cpt =
        Tezos_stdlib_unix.Utils.display_progress
          ~refresh_rate:(cpt, 1_000)
          (fun m ->
            m
              "Context: %dK elements, %dMiB read"
              (cpt / 1_000)
              (!read / 1_048_576)) ;
        get_command rbuf
        >>=? function
        | Root {block_header; info; parents; block_data} -> (
            I.set_context ~info ~parents ctxt block_header
            >>= function
            | None ->
                fail Inconsistent_snapshot_data
            | Some block_header ->
                return (block_header, block_data) )
        | Node contents ->
            add_dir batch contents
            >>=? fun tree ->
            first_pass batch (I.update_context ctxt tree) (cpt + 1)
        | Blob data ->
            add_blob batch data
            >>=? fun tree ->
            first_pass batch (I.update_context ctxt tree) (cpt + 1)
        | _ ->
            fail Inconsistent_snapshot_data
      in
      let rec second_pass pred_header (rev_block_hashes, protocol_datas) todo
          cpt =
        Tezos_stdlib_unix.Utils.display_progress
          ~refresh_rate:(cpt, 1_000)
          (fun m ->
            m
              "Store: %dK elements, %dMiB read"
              (cpt / 1_000)
              (!read / 1_048_576)) ;
        get_command rbuf
        >>=? function
        | Proot pruned_block ->
            let header = I.Pruned_block.header pruned_block in
            let hash = Block_header.hash header in
            block_validation pred_header hash pruned_block
            >>=? fun () ->
            if (cpt + 1) mod 5_000 = 0 then
              k_store_pruned_blocks ((hash, pruned_block) :: todo)
              >>=? fun () ->
              second_pass
                (Some header)
                (hash :: rev_block_hashes, protocol_datas)
                []
                (cpt + 1)
            else
              second_pass
                (Some header)
                (hash :: rev_block_hashes, protocol_datas)
                ((hash, pruned_block) :: todo)
                (cpt + 1)
        | Loot protocol_data ->
            k_store_pruned_blocks todo
            >>=? fun () ->
            second_pass
              pred_header
              (rev_block_hashes, protocol_data :: protocol_datas)
              todo
              (cpt + 1)
        | End ->
            return (pred_header, rev_block_hashes, List.rev protocol_datas)
        | _ ->
            fail Inconsistent_snapshot_data
      in
      I.batch index (fun batch -> first_pass batch (I.make_context index) 0)
      >>=? fun (block_header, block_data) ->
      Tezos_stdlib_unix.Utils.display_progress_end () ;
      second_pass None ([], []) [] 0
      >>=? fun (oldest_header_opt, rev_block_hashes, protocol_datas) ->
      Tezos_stdlib_unix.Utils.display_progress_end () ;
      return
        ( block_header,
          block_data,
          history_mode,
          oldest_header_opt,
          rev_block_hashes,
          protocol_datas )
    in
    Lwt.catch
      (fun () ->
        (* Check snapshot version *)
        read_snapshot_metadata rbuf
        >>=? fun version ->
        check_version version >>=? fun () -> restore version.mode)
      (function
        | Unix.Unix_error (e, _, _) ->
            fail (System_read_error (Unix.error_message e))
        | Invalid_argument _ ->
            fail Inconsistent_snapshot_file
        | err ->
            Lwt.fail err)
end
