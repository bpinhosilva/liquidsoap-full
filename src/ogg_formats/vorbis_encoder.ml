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

let create_gen enc freq m = 
  let p1,p2,p3 = Vorbis.Encoder.headerout_packetout enc m in
  let started  = ref false in
  let header_encoder os = 
    Ogg.Stream.put_packet os p1;
    Ogg.Stream.flush_page os
  in
  let fisbone_packet os = 
    Some (Vorbis.Skeleton.fisbone
           ~serialno:(Ogg.Stream.serialno os)
           ~samplerate:(Int64.of_int freq) ())
  in
  let stream_start os = 
    Ogg.Stream.put_packet os p2;
    Ogg.Stream.put_packet os p3;
    Ogg_encoder.flush_pages os
  in
  let data_encoder data os _ =
    if not !started then
      started := true;
    let b,ofs,len = data.Ogg_encoder.data,data.Ogg_encoder.offset,
                    data.Ogg_encoder.length in
    Vorbis.Encoder.encode_buffer_float enc os b ofs len
  in
  let empty_data () =
    Array.make
       (Lazy.force Frame.audio_channels)
       (Array.make 1 0.)
  in
  let end_of_page p =
    let granulepos = Ogg.Page.granulepos p in
    if granulepos < Int64.zero then
      Ogg_encoder.Unknown
    else
      Ogg_encoder.Time (Int64.to_float granulepos /. (float freq))
  in
  let end_of_stream os =
    (* Assert that at least some data was encoded.. *)
    if not !started then
      begin
        let b = empty_data () in
        Vorbis.Encoder.encode_buffer_float enc os b 0 (Array.length b.(0));
      end;
    Vorbis.Encoder.end_of_stream enc os
  in
  {
   Ogg_encoder.
    header_encoder = header_encoder;
    fisbone_packet = fisbone_packet;
    stream_start   = stream_start;
    data_encoder   = (Ogg_encoder.Audio_encoder data_encoder);
    end_of_page    = end_of_page;
    end_of_stream  = end_of_stream
  }

let create_abr ~channels ~samplerate ~min_rate 
               ~max_rate ~average_rate ~metadata () = 
  let enc = 
    Vorbis.Encoder.create channels samplerate max_rate 
                          average_rate min_rate 
  in
  create_gen enc samplerate metadata

let create_cbr ~channels ~samplerate ~bitrate ~metadata () = 
  create_abr ~channels ~samplerate ~min_rate:bitrate 
             ~max_rate:bitrate ~average_rate:bitrate 
             ~metadata ()

let create ~channels ~samplerate ~quality ~metadata () = 
  let enc = 
    Vorbis.Encoder.create_vbr channels samplerate quality 
  in
  create_gen enc samplerate metadata

