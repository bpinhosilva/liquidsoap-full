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

open Source

exception Internal

let speex_proto = [
  "samplerate",
  Lang.int_t,
  Some (Lang.int (-1)),
  Some ("Output sample rate. Use liquidsoap's default if <= 0.");

  "bitrate",
  Lang.int_t,
  Some (Lang.int (-1)),
  Some "Target bitrate (in kbps). Not used if <= 0.";

  "quality",
  Lang.int_t,
  Some (Lang.int 7),
  Some "Target quality (0 to 10). Not used if <= 0.";

  "mode",
  Lang.string_t,
  Some (Lang.string "narrowband"),
  Some "Encoding mode, one of \"narrowband\", \"wideband\" \
        or \"ultra-wideband\".";

  "stereo",
  Lang.bool_t,
  Some (Lang.bool false),
  None;

  "vbr",
  Lang.bool_t,
  Some (Lang.bool false),
  Some "Encode in vbr mode.";

  "frames_per_packet",
  Lang.int_t,
  Some (Lang.int 1),
  Some "Number of frame per Ogg packet (1 to 10).";

  "complexity",
  Lang.int_t,
  Some (Lang.int (-1)),
  Some "Encoding complexity (0-10). Not used if <= 0.";

  "abr",
  Lang.int_t,
  Some (Lang.int (-1)),
  Some "Set average bitrate. Not used if <= 0.";
] @ (Ogg_output.ogg_proto false)

exception Invalid_settings of string

let create ~freq ~stereo ~mode 
           ~bitrate ~vbr ~fpp 
           ~complexity ~abr ~quality () =
  if Fmt.channels () < 2 && stereo then
   raise (Invalid_settings "not enought channels");
  let channels =
    if stereo then 2 else 1
  in
  let f x = 
    if x > 0 then
     Some x
    else 
     None
  in
  let freq =
    if freq > 0 then
      bitrate
    else
      Fmt.samples_per_second ()
  in
  let bitrate = f bitrate in
  let abr = f abr in
  let quality = f quality in
  let complexity = f complexity in 
  let dst_freq = float (Fmt.samples_per_second()) in
  let src_freq = 
    if freq > 0 then
      float freq
    else
      dst_freq
  in
  let stereo = 
    if Fmt.channels () = 1 then
      false
    else
      stereo
  in
  let create_encoder ogg_enc m =
    let rec get l l' =
      match l with
        | k :: r ->
          begin
            try
              get r ((k,List.assoc k m) :: l')
            with _ -> get r l'
          end
        | [] -> l'
    in
    let title =
      try
        List.assoc "title" m
      with
        | _ ->
        begin
          try
            let s = List.assoc "uri" m in
            let title = Filename.basename s in
                (try
                   String.sub title 0 (String.rindex title '.')
                 with
                   | Not_found -> title)
          with
            | _ -> "Unknown"
        end
    in
    let l' = ["title",title] in
    let metadata = get ["artist";"genre";"date";
                    "album";"tracknumber";"comment"]
                   l'
    in
    let enc = 
      Speex_format.create ~frames_per_packet:fpp ~mode ~vbr ~quality
                          ~channels ~bitrate ~samplerate:freq 
                          ~abr ~complexity ~metadata ()
    in
    Ogg_encoder.register_track ogg_enc enc
  in
  let encode =
    Ogg_output.encode_audio
      ~stereo ~dst_freq ~src_freq ()
  in
  create_encoder,encode 

let () =
  Lang.add_operator "output.file.speex"
    (speex_proto @ File_output.proto @ Output.proto @
     [
      "start",
      Lang.bool_t, Some (Lang.bool true),
      Some "Start output on operator initialization." ;

      "", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:("Output the source stream as an Ogg speex file.")
    (fun p _ ->
       let e f v = f (List.assoc v p) in
       let autostart = e Lang.to_bool "start" in
       let stereo = e Lang.to_bool "stereo" in
       let skeleton = e Lang.to_bool "skeleton" in
       let bitrate = (e Lang.to_int "bitrate") in
       let bitrate = 
         if bitrate > 0 then
           bitrate * 1024
         else
           bitrate
       in
       let vbr = e Lang.to_bool "vbr" in
       let fpp = e Lang.to_int "frames_per_packet" in
       let freq = e Lang.to_int "samplerate" in
       let quality = e Lang.to_int "quality" in
       let abr = (e Lang.to_int "abr") * 1000 in
       let complexity = e Lang.to_int "complexity" in
       let mode = 
         match e Lang.to_string "mode" with
           | "narrowband" -> Speex.Narrowband
           | "wideband" -> Speex.Wideband
           | "ultra-wideband" -> Speex.Ultra_wideband
           | _ -> failwith "Unknown speex mode"
       in
       let name = Lang.to_string (Lang.assoc "" 1 p) in
       let append = Lang.to_bool (List.assoc "append" p) in
       let perm = Lang.to_int (List.assoc "perm" p) in
       let dir_perm = Lang.to_int (List.assoc "dir_perm" p) in
       let reload_predicate = List.assoc "reopen_when" p in
       let reload_delay = Lang.to_float (List.assoc "reopen_delay" p) in
       let reload_on_metadata =
         Lang.to_bool (List.assoc "reopen_on_metadata" p)
       in
       let streams = 
        ["speex",create ~freq ~stereo ~mode 
                        ~bitrate ~vbr ~fpp 
                        ~complexity ~abr ~quality ()]
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
       let source = Lang.assoc "" 2 p in
         ((new Ogg_output.to_file 
             ~infallible ~on_stop ~on_start
             name ~append ~perm ~dir_perm ~streams ~skeleton
             ~reload_delay ~reload_predicate ~reload_on_metadata
             ~autostart source):>source))

