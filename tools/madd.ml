open Printf

module Top
    (Opt:
       sig
         val verbose : bool
         val tnames : bool
	 val ncheck : bool
       end) =
  struct

    module T = struct
      type t = 
        { tname : string ;
          hash : string option; } 
    end

    module Make(A:ArchBase.S) = struct

      let zyva name parsed =
	let tname = name.Name.name in
	let hash = MiscParser.get_hash parsed in
	if Opt.verbose 
	then printf "Name=%s\nHash=%s\n\n"
			   tname
			    (match hash with 
			    | None -> "none" 
			    | Some h -> h);
        { T.tname = tname ;
          hash = hash; }
    end

    module Z = ToolParse.Top(T)(Make)

    type name = {fname:string; tname:string;}

    let do_test name k =
      try
        let {T.tname = tname;
             hash = h; } = Z.from_file name in
        ({fname=name; tname=tname;},h)::k
      with
      | Misc.Exit -> k
      | Misc.Fatal msg ->
          Warn.warn_always "%a %s" Pos.pp_pos0 name msg ;
          k
      | e ->
          eprintf "\nFatal: %a Adios\n" Pos.pp_pos0 name ;
          raise e

    let zyva tests =
      let xs = match tests with
	| [] -> raise (Misc.Fatal "No given tests base\n")
	| [base] -> if Opt.verbose 
		    then eprintf "#From base : %s" base; 
		    (Misc.fold_argv do_test [base] [],
		     Misc.fold_stdin do_test [])
	| base::tests -> if Opt.verbose 
			 then eprintf "#From base : %s" base; 
			 (Misc.fold_argv do_test [base] [],
			  Misc.fold_argv do_test tests []) in

      let tname_compare f1 f2 =
        let f1 = f1.tname and f2 = f2.tname in
        String.compare f1 f2
      in

      let xs =
	let rec exists (f,h) = function
	  | [] -> false
	  | (f',h')::tail -> 
	     let sameh = h = h' in 
	     let samen = tname_compare f f' = 0 in
	     match samen,sameh with
	     | true,true -> true
	     | false,true -> if Opt.ncheck
			     then true
			     else exists (f,h) tail
	     | true,false -> Warn.warn_always 
			     "%s already exists in %s." f'.fname f.fname;
			     true
	     | _ -> exists (f,h) tail
	in List.filter (fun n -> not (exists n (fst xs))) (snd xs)
      in

      let () =
        printf "#" ;
        for k = 0 to Array.length Sys.argv-1 do
          printf " %s" Sys.argv.(k)
        done ;
        printf "\n" ;
        let pname =
          if Opt.tnames then (fun n -> n.tname) else (fun n -> n.fname) in
        List.iter (fun (f,_) -> printf "%s\n" (pname f)) xs
      in
      ()
  end


let verbose = ref false
let arg = ref []
let base = ref ""
let tnames = ref false
let ncheck = ref false
let prog =
  if Array.length Sys.argv > 0 then Sys.argv.(0)
  else "madd"

let () =
  Arg.parse
    ["-v",Arg.Unit (fun () -> verbose := true), " be verbose";
     "-t",Arg.Unit (fun () -> tnames := true)," output test names";
     "-s",Arg.Unit (fun () -> ncheck := true)," do not add already existing tests with different names"]       
    (fun s -> arg := s :: !arg)
    (sprintf "Usage: %s [options]* [test]*" prog)

let tests = List.rev !arg

let parse_int s = try Some (int_of_string s) with _ -> None

module L = LexRename.Make(struct let verbose = if !verbose then 1 else 0 end)

module X =
  Top
    (struct
      let verbose = !verbose
      let tnames = !tnames
      let ncheck = !ncheck
    end)

let () = X.zyva tests
