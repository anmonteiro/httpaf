open Httpaf
open Httpaf.Httpaf_private

let debug msg =
  if true then Printf.eprintf "%s\n%!" msg

let request_to_string r =
  let f = Faraday.create 0x1000 in
  Serialize.write_request f r;
  Faraday.serialize_to_string f

let response_to_string r =
  let f = Faraday.create 0x1000 in
  Serialize.write_response f r;
  Faraday.serialize_to_string f

let body_to_strings = function
  | `Empty       -> []
  | `Fixed   xs  -> xs
  | `Chunked xs  ->
    List.fold_right (fun x acc ->
      let len = String.length x in
      [Printf.sprintf "%x\r\n" len; x; "\r\n"] @ acc)
    xs [ "0\r\n" ]
;;

let case_to_strings = function
  | `Request  r, body -> [request_to_string  r] @ (body_to_strings body)
  | `Response r, body -> [response_to_string r] @ (body_to_strings body)

let response_stream_to_body (`Response response, body) =
  let response = response_to_string response in
  match body with
  | `Empty  -> response
  | `Fixed xs | `Chunked xs -> String.concat "" (response :: xs)

let iovec_to_string { IOVec.buffer; off; len } =
  Bigstringaf.substring ~off ~len buffer

let bigstring_append_string bs s =
  let bs_len = Bigstringaf.length bs in
  let s_len  = String.length s in
  let bs' = Bigstringaf.create (bs_len + s_len) in
  Bigstringaf.blit             bs ~src_off:0 bs' ~dst_off:0      ~len:bs_len;
  Bigstringaf.blit_from_string s  ~src_off:0 bs' ~dst_off:bs_len ~len:s_len;
  bs'
;;

let bigstring_empty = Bigstringaf.empty

let test_client ~request ~request_body_writes ~response_stream () =
  let reads  = case_to_strings response_stream in
  let writes = case_to_strings (`Request request, `Fixed request_body_writes) in
  let test_input  = ref []    in
  let got_eof     = ref false in
  let error_handler _ = assert false in
  let response_handler response response_body =
    test_input := (response_to_string response) :: !test_input;
    let rec on_read bs ~off ~len =
      test_input := Bigstringaf.substring bs ~off ~len :: !test_input;
      Body.schedule_read response_body ~on_read ~on_eof
    and on_eof () = got_eof := true in
    Body.schedule_read response_body ~on_read ~on_eof
  in
  let body, conn =
    Client_connection.request
      request
      ~error_handler
      ~response_handler
  in
  let rec loop conn request_body_writes input reads =
    if Client_connection.is_closed conn
    then []
    else begin
      let input', reads'               = iloop conn input reads in
      let output, request_body_writes' = oloop conn request_body_writes in
      output @ loop conn request_body_writes' input' reads'
    end
  and oloop conn request_body =
    let request_body' =
      match request_body with
      | []      -> Body.close_writer body; request_body
      | x :: xs -> Body.write_string body x; Body.flush body ignore; xs
    in
    match Client_connection.next_write_operation conn with
    | `Yield   ->
      (* This should only happen once to close the writer *)
      Client_connection.yield_writer conn ignore; [], request_body'
    | `Close _ ->
      debug " client oloop: closed"; [], request_body'
    | `Write iovecs ->
      debug " client oloop: write";
      let output = List.map iovec_to_string iovecs in
      Client_connection.report_write_result conn (`Ok (IOVec.lengthv iovecs));
      output, request_body'
  and iloop conn input reads =
    match Client_connection.next_read_operation conn, reads with
    | `Read, read::reads' ->
      debug " client iloop: read";
      let input     = bigstring_append_string input read in
      let input_len = Bigstringaf.length input in
      let result     = Client_connection.read conn input ~off:0 ~len:input_len in
      if result = input_len
      then bigstring_empty, reads'
      else Bigstringaf.sub ~off:result ~len:(input_len - result) input, reads'
    | `Read, [] ->
      debug " client iloop: eof";
      let input_len = Bigstringaf.length input in
      ignore (Client_connection.read_eof conn input ~off:0 ~len:input_len : int);
      input, []
    | _          , [] ->
      debug " client iloop: eof";
      let input_len = Bigstringaf.length input in
      ignore (Client_connection.read_eof conn input ~off:0 ~len:input_len : int);
      input, []
    | `Close    , _     ->
      debug " client iloop: close(ok)";
      input, []
  in
  let test_output = loop conn request_body_writes bigstring_empty reads |> String.concat "" in
  let test_input  = List.rev !test_input |> String.concat "" in
  let input       = response_stream_to_body response_stream in
  let output      = String.concat "" writes in
  Alcotest.(check bool   "got eof"  true   !got_eof);
  Alcotest.(check string "request"  output test_output);
  Alcotest.(check string "response" input  test_input);
;;
