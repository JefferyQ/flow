(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Utils_js

module Result = Core_result
let (>>=) = Result.(>>=)

let compute_docblock file content =
  let open Parsing_service_js in
  let max_tokens = docblock_max_tokens in
  let _errors, docblock = parse_docblock ~max_tokens file content in
  docblock

(* We use compute_ast_result (as opposed to get_ast_result) when the file contents we have might be
 * different from what's on disk (and what is therefore stored in shared memory). This can be the
 * case for local find-refs requests, where the client may pipe in file contents rather than just
 * specifying a filename. For global find-refs, we assume that all dependent files are the same as
 * what's on disk, so we can grab the AST from the heap instead. *)
let compute_ast_result options file content =
  let module_ref_prefix = Options.haste_module_ref_prefix options in
  let facebook_fbt = Options.facebook_fbt options in
  let arch = options.Options.opt_arch in
  let docblock = compute_docblock file content in
  let open Parsing_service_js in
  let types_mode = TypesAllowed in
  let use_strict = true in
  let result = do_parse ~fail:false ~types_mode ~use_strict ~info:docblock
    ~module_ref_prefix ~facebook_fbt ~arch content file in
  match result with
    | Parse_ok parse_ok ->
      let ast, file_sig = basic parse_ok in
      Ok (ast, file_sig, docblock)
    (* The parse should not fail; we have passed ~fail:false *)
    | Parse_fail _ -> Error "Parse unexpectedly failed"
    | Parse_skip _ -> Error "Parse unexpectedly skipped"

let get_ast_result ~reader file
    : ((Loc.t, Loc.t) Flow_ast.program * File_sig.With_Loc.t * Docblock.t, string) result =
  let open Parsing_heaps in
  let get_result f kind =
    let error =
      Printf.sprintf "Expected %s to be available for %s"
        kind
        (File_key.to_string file)
    in
    Result.of_option ~error (f file)
  in
  let ast_result = get_result (Reader.get_ast ~reader) "AST" in
  let file_sig_result = get_result (Reader.get_file_sig ~reader) "file sig" in
  let docblock_result = get_result (Reader.get_docblock ~reader) "docblock" in
  ast_result >>= fun ast ->
  file_sig_result >>= fun file_sig ->
  docblock_result >>= fun docblock ->
  Ok (ast, file_sig, docblock)

let get_dependents ~reader options workers env file_key content =
  let docblock = compute_docblock file_key content in
  let reader = Abstract_state_reader.State_reader reader in
  let modulename = Module_js.exported_module ~options ~reader file_key docblock in
  Dep_service.dependent_files
    ~reader
    workers
    (* Surprisingly, creating this set doesn't seem to cause horrible performance but it's
    probably worth looking at if you are searching for optimizations *)
    ~candidates:ServerEnv.(CheckedSet.all !env.checked_files)
    ~root_files:(FilenameSet.singleton file_key)
    ~root_modules:(Modulename.Set.singleton modulename)
