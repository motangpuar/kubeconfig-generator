open Printf

let read_file filename =
  let ic = open_in filename in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file filename content =
  let oc = open_out filename in
  output_string oc content;
  close_out oc

let substitute_vars content vars =
  List.fold_left (fun acc (key, value) ->
    Str.global_replace (Str.regexp_string key) value acc
  ) content vars

let exec cmd =
  printf "Executing: %s\n" cmd;
  flush stdout;
  let exit_code = Sys.command cmd in
  if exit_code <> 0 then
    failwith (sprintf "Command failed: %s" cmd)

let exec_ignore_error cmd =
  printf "Cleanup: %s\n" cmd;
  flush stdout;
  ignore (Sys.command (sprintf "%s 2>/dev/null" cmd))

let parse_config filename =
  let content = read_file filename in
  Yojson.Basic.from_string content

let extract_vars json =
  let open Yojson.Basic.Util in
  json |> to_assoc |> List.map (fun (k, v) -> (k, to_string v))

let process_template template_file vars output_file =
  let content = read_file template_file in
  let processed = substitute_vars content vars in
  write_file output_file processed

let apply_manifest kubeconfig manifest_file =
  exec (sprintf "kubectl --kubeconfig=%s apply -f %s" kubeconfig manifest_file)

(* let delete_manifest kubeconfig manifest_file =
  exec_ignore_error (sprintf "kubectl --kubeconfig=%s delete -f %s --ignore-not-found=true" kubeconfig manifest_file) *)

let generate_cert cert_dir username email =
  exec (sprintf "mkdir -p %s" cert_dir);
  let key = sprintf "%s/%s.key" cert_dir username in
  let csr = sprintf "%s/%s.csr" cert_dir username in
  let crt = sprintf "%s/%s.crt" cert_dir username in

  exec (sprintf "openssl genrsa -out %s 2048" key);
  exec (sprintf "openssl req -new -key %s -out %s -subj '/CN=%s/O=dev-team'" key csr email);
  exec (sprintf "openssl x509 -req -in %s -CA tmp/ca.crt -CAkey tmp/ca.key -CAcreateserial -out %s -days 365" csr crt);

  (key, crt)

let get_server () =
  let ic = Unix.open_process_in "kubectl --kubeconfig=tmp/admin.kubeconfig config view --minify -o jsonpath='{.clusters[0].cluster.server}'" in
  let server = input_line ic in
  ignore (Unix.close_process_in ic);
  server

let cleanup_resources namespace username =
  printf "\n=== Cleaning up resources ===\n";
  exec_ignore_error (sprintf "kubectl --kubeconfig=tmp/admin.kubeconfig delete clusterrolebinding %s-cluster-viewer" username);
  exec_ignore_error (sprintf "kubectl --kubeconfig=tmp/admin.kubeconfig delete clusterrole cluster-viewer-%s" username);
  exec_ignore_error (sprintf "kubectl --kubeconfig=tmp/admin.kubeconfig delete namespace %s" namespace);
  printf "=== Cleanup complete ===\n\n"

let provision config_file =
  let json = parse_config config_file in
  let open Yojson.Basic.Util in

  let username = json |> member "username" |> to_string in
  let email = json |> member "email" |> to_string in
  let namespace = json |> member "namespace" |> to_string in

  let vars = extract_vars json in
  let template_vars = List.map (fun (k, v) -> (sprintf "{{%s}}" (String.uppercase_ascii k), v)) vars in

  printf "\n=== Provisioning user: %s ===\n" username;

  exec "mkdir -p generated/manifests";

  let templates = ["namespace"; "role"; "rolebinding"; "clusterrole"; "clusterrolebinding"] in
  let manifest_files = List.map (fun tmpl ->
    let src = sprintf "templates/%s.yaml" tmpl in
    let dst = sprintf "generated/manifests/%s-%s.yaml" namespace tmpl in
    process_template src template_vars dst;
    dst
  ) templates in

  try
    (* Step 1: Generate certificates FIRST *)
    printf "\n--- Generating certificates ---\n";
    let cert_dir = sprintf "generated/%s" namespace in
    let (key_file, crt_file) = generate_cert cert_dir username email in
    printf "Certificates generated successfully\n";

    (* Step 2: Get cluster info *)
    let server = get_server () in

    (* Step 3: Generate kubeconfig *)
    let ca_b64 = Base64.encode_string (read_file "tmp/ca.crt") in
    let key_b64 = Base64.encode_string (read_file key_file) in
    let crt_b64 = Base64.encode_string (read_file crt_file) in

    let kubeconfig_vars = template_vars @ [
      ("{{SERVER}}", server);
      ("{{CA_DATA}}", ca_b64);
      ("{{CLIENT_CERT_DATA}}", crt_b64);
      ("{{CLIENT_KEY_DATA}}", key_b64);
    ] in

    let kubeconfig_file = sprintf "generated/%s-kubeconfig.yaml" username in
    process_template "templates/kubeconfig.yaml" kubeconfig_vars kubeconfig_file;
    printf "Kubeconfig generated successfully\n";

    (* Step 4: Apply manifests ONLY after everything else succeeded *)
    printf "\n--- Applying Kubernetes manifests ---\n";
    List.iter (fun manifest ->
      apply_manifest "tmp/admin.kubeconfig" manifest
    ) manifest_files;

    printf "\n=== SUCCESS ===\n";
    printf "Generated kubeconfig: %s\n" kubeconfig_file;
    printf "=== Provisioning complete ===\n\n"

  with
  | Failure msg ->
      printf "\n=== ERROR ===\n";
      printf "%s\n" msg;
      printf "\nRolling back any applied resources...\n";
      cleanup_resources namespace username;
      exit 1
  | e ->
      printf "\n=== ERROR ===\n";
      printf "%s\n" (Printexc.to_string e);
      printf "\nRolling back any applied resources...\n";
      cleanup_resources namespace username;
      exit 1

let revoke config_file =
  let json = parse_config config_file in
  let open Yojson.Basic.Util in

  let username = json |> member "username" |> to_string in
  let namespace = json |> member "namespace" |> to_string in

  printf "\n=== Revoking user: %s ===\n" username;
  cleanup_resources namespace username;
  printf "=== Revocation complete ===\n\n"

let () =
  if Array.length Sys.argv < 2 then begin
    printf "Usage:\n";
    printf "  Provision: %s <config.json>\n" Sys.argv.(0);
    printf "  Revoke:    %s --revoke <config.json>\n" Sys.argv.(0);
    exit 1
  end;

  if Array.length Sys.argv >= 3 && Sys.argv.(1) = "--revoke" then
    revoke Sys.argv.(2)
  else
    provision Sys.argv.(1)
