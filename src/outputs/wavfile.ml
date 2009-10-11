(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Output in a WAV file. *)

class output
  ~append ~perm ~dir_perm ~infallible ~on_stop ~on_start
  ~reload_delay ~reload_predicate ~reload_on_metadata
  name source autostart =
  let channels = Fmt.channels () in
  let sample_rate = Fmt.samples_per_second () in
object
  inherit Output.encoded 
            ~infallible ~on_stop ~on_start
            ~name ~kind:"output.file" ~autostart source
  inherit File_output.to_file
            ~reload_delay ~reload_predicate ~reload_on_metadata
            ~append ~perm ~dir_perm name as to_file

  val header = Wav.header ~channels ~sample_rate ~sample_size:16 ~big_endian:false ~signed:true ()
  val mutable need_header = false

  method reset_encoder m =
    to_file#on_reset_encoder ;
    to_file#set_metadata (Hashtbl.find (Hashtbl.copy m)) ;
    need_header <- need_close ;
    ""

  method encode frame start len =
    let b = AFrame.get_float_pcm frame in
    let start = Fmt.samples_of_ticks start in
    let len = Fmt.samples_of_ticks len in
    let s = String.create (2 * len * channels) in
    ignore(Float_pcm.to_s16le b start len s 0) ;
    if need_header then 
      begin
        need_header <- false ;
        header ^ s
      end
    else
      s

  method output_start =
    to_file#file_start ;
    to_file#send header

  method output_stop =
    to_file#file_stop

  method output_reset = ()
end

let () =
  Lang.add_operator "output.file.wav"
    ((( "start", Lang.bool_t, Some (Lang.bool true), None) :: File_output.proto)
      @ Output.proto @ ["", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:"Output the source's stream to a WAV file."
    (fun p _ ->
       let autostart = Lang.to_bool (List.assoc "start" p) in
       let name = Lang.to_string (Lang.assoc "" 1 p) in
       let source = Lang.assoc "" 2 p in
       let append = Lang.to_bool (List.assoc "append" p) in
       let perm = Lang.to_int (List.assoc "perm" p) in
       let dir_perm = Lang.to_int (List.assoc "dir_perm" p) in
       let reload_predicate = List.assoc "reopen_when" p in
       let reload_delay = Lang.to_float (List.assoc "reopen_delay" p) in
       let reload_on_metadata =
         Lang.to_bool (List.assoc "reopen_on_metadata" p)
       in
       let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
       let on_start =
         let f = List.assoc "on_start" p in
           fun () -> ignore (Lang.apply f [])
       in
       let on_stop =
         let f = List.assoc "on_stop" p in
           fun () -> ignore (Lang.apply f [])
       in
         ((new output ~append ~perm ~dir_perm
             ~infallible ~on_stop ~on_start
             ~reload_delay ~reload_predicate ~reload_on_metadata 
             name source autostart):>Source.source))
