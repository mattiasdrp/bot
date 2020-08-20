open Base
open Helpers

let toml_of_file file_path = Toml.Parser.(from_filename file_path |> unsafe)

let toml_of_string s = Toml.Parser.(from_string s |> unsafe)

let find k = TomlTypes.Table.find (Toml.key k)

let subkey_value toml_table k k' =
  TomlLenses.(get toml_table (key k |-- table |-- key k' |-- string))

let list_table_keys toml_table =
  TomlTypes.Table.fold
    (fun k _ ks -> TomlTypes.Table.Key.to_string k :: ks)
    toml_table []

let string_of_mapping =
  Hashtbl.fold ~init:"" ~f:(fun ~key ~data acc -> acc ^ f "(%s, %s)\n" key data)

let port toml_data =
  Option.value_map
    (subkey_value toml_data "server" "port")
    ~f:Int.of_string
    ~default:
      (Option.value_map (Sys.getenv "PORT") ~f:Int.of_string ~default:8000)

let gitlab_access_token toml_data =
  match subkey_value toml_data "gitlab" "api_token" with
  | None ->
      Sys.getenv_exn "GITLAB_ACCESS_TOKEN"
  | Some secret ->
      secret

let github_access_token toml_data =
  match subkey_value toml_data "github" "api_token" with
  | None ->
      Sys.getenv_exn "GITHUB_ACCESS_TOKEN"
  | Some secret ->
      secret

let github_webhook_secret toml_data =
  match subkey_value toml_data "github" "webhook_secret" with
  | None ->
      Sys.getenv_exn "GITHUB_WEBHOOK_SECRET"
  | Some secret ->
      secret

let gitlab_webhook_secret toml_data =
  match subkey_value toml_data "gitlab" "webhook_secret" with
  | None ->
      Option.value
        ~default:(github_webhook_secret toml_data)
        (Sys.getenv "GITLAB_WEBHOOK_SECRET")
  | Some secret ->
      secret

let bot_name toml_data =
  Option.value_map
    (subkey_value toml_data "bot" "name")
    ~f:String.of_string ~default:"coqbot"

let bot_domain toml_data =
  Option.value_map
    (subkey_value toml_data "server" "domain")
    ~f:String.of_string
    ~default:(f "%s.herokuapp.com" (bot_name toml_data))

let bot_email toml_data =
  Option.value_map
    (subkey_value toml_data "bot" "email")
    ~f:String.of_string
    ~default:(f "%s@users.noreply.github.com" (bot_name toml_data))

let github_app_id toml_data =
  match subkey_value toml_data "github" "app_id" with
  | None ->
      let id = Sys.getenv_exn "GITHUB_APP_ID" |> Int.of_string in
      Stdio.printf "Found github app id: %d\n" id ;
      id
  | Some secret ->
      secret |> Int.of_string

(*let string_of_file_path path = Stdio.In_channel.(with_file path ~f:input_all)*)

let github_private_key =
  (*string_of_file_path "./github.private-key.pem"*)
  match
    let private_k =
      Option.value_exn ~message:"GITHUB_PRIVATE_KEY env variable missing!"
        (Sys.getenv "GITHUB_PRIVATE_KEY")
    in
    Stdio.eprintf "Found private key: %s\n" private_k ;
    private_k |> Cstruct.of_string |> X509.Private_key.decode_pem
  with
  | Ok (`RSA priv) ->
      Stdio.printf "Private key bit size: %d\n"
        (Mirage_crypto_pk.Rsa.priv_bits priv) ;
      priv
  | Error (`Msg e) ->
      raise (Failure (f "%s" e))

let parse_mappings mappings =
  let keys = list_table_keys mappings in
  let assoc =
    List.(
      fold_left
        ~f:(fun assoc_table k ->
          (subkey_value mappings k "github", subkey_value mappings k "gitlab")
          :: assoc_table)
        ~init:[] keys
      |> filter_map ~f:(function
           | Some gh, Some gl ->
               Some (gh, gl)
           | _, _ ->
               None))
  in
  let assoc_rev = List.map assoc ~f:(fun (gh, gl) -> (gl, gh)) in
  let get_table t =
    match t with
    | `Duplicate_key _ ->
        raise (Failure "Duplicate key in config.")
    | `Ok t ->
        t
  in
  ( get_table (Hashtbl.of_alist (module String) assoc)
  , get_table (Hashtbl.of_alist (module String) assoc_rev) )

let make_mappings_table toml_data =
  let toml_mappings =
    match find "mappings" toml_data with
    | TomlTypes.TTable a ->
        Some a
    | _ ->
        None
  in
  Option.value_exn toml_mappings
    ~message:"No mappings field found in toml config file."
  |> parse_mappings
