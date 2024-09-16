let filename = Sys.argv.(1) ;;
(* Printf.printf "%s\n" filename *)

let () =
  let ic = open_in filename in
    let line = input_line ic in
    print_endline line;
    flush stdout;
    close_in ic

(* Split Threads *)


(* Return Type? *)
