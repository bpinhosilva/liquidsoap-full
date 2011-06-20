(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

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

(** A few things should be shared among several sources. *)

(* TODO SERIOUSLY
 * These I/O operators are deprecated and the code has several problems.
 * The global initialization doesn't support on-the-fly creation/deletion
 * of inputs/outputs. It also has several scary comments.
 * The only reason to keep this code around is that some people may still
 * use it... should we force the migration to bjack, and when? *)

(** Dedicated Jack clock. *)
let get_clock = Tutils.lazy_cell (fun () -> new Clock.self_sync "jack")

let log = Dtools.Log.make ["jack"]

let need_jack = ref false

let conf =
  Dtools.Conf.void ~p:(Configure.conf#plug "jack") "JACK settings"
let client_name =
  Dtools.Conf.string ~p:(conf#plug "client_name") ~d:"liquidsoap-<pid>"
    "Client name"
    ~comments:[
      "Name of the JACK client, where <pid> is replaced by liquidsoap's PID,";
      "and <script> by the base name of the .liq script if one is used."
    ]

module Ringbuffer = Jack.Ringbuffer.Float

let client =
  let client = ref None in
  let init () =
    if !need_jack then
      let name = Configure.subst_vars (client_name#get) in
        log#f 3 "Creating client %S..." name ;
        let jc = Jack.Client.create name in
          (* TODO: this causes liquidsoap to segfault, we should
           * investigate why... *)
          (*
          Jack.Client.on_shutdown jc
            (fun () -> failwith "Jack server was shut down!");
          *)
          client := Some jc
  in
    ignore (Dtools.Init.at_start init) ;
    fun () ->
      match !client with
        | None -> assert false
        | Some c -> c

let add_ringbuffer_callback, (activate, reset) =
  let l = ref [] in
    (fun x -> l := x :: !l),
    let activated = ref false in
      (
        fun () ->
          if not !activated then
            let client = client () in
              log#f 3 "Activating %d port(s)..." (List.length !l) ;
              activated := true ;
              Jack.Client.set_process_ringbuffer_callback client !l ;
              Jack.Client.activate client
      ),
      (
        fun () ->
          let client = client () in
          log#f 3 "Reconnecting to Jack...";
          Jack.Client.deactivate client;
          (* Empty the ringbuffers. *)
          List.iter
            (fun (_, r, _) ->
               Ringbuffer.read_advance r (Ringbuffer.read_space r)) !l;
          Jack.Client.activate client;
      )

(* The ringbuffer between us and the Jack engine, interleaved. The
 * multiplication by 8 is an heuristic which seems to avoid underruns... *)
let ringbuffer_coeff = Dtools.Conf.int ~p:(conf#plug "ringbuffer_coeff") ~d:8
    "Ringbuffer coefficient"
    ~comments:[
      "The ringbuffer between us and the Jack engine, interleaved. The";
      "multiplication by 8 is an heuristic which seems to avoid underruns.";
      "Should be supperior or equal to 4."
    ]

class virtual base ~kind port_names mode =
object
  val channels = (Frame.type_of_kind kind).Frame.audio
  val samples_per_frame = AFrame.size ()

  initializer need_jack := true

  method stype = Source.Infallible
  method is_ready = true
  method remaining = -1

  method abort_track  = ()

  method output_reset = ()
  method is_active = true

  val mutable ring = [||]
  initializer
    if ringbuffer_coeff#get < 4 then failwith "ringbuffer_coeff must be >= 4" ;
    ring <- Array.init
      (Array.length port_names)
      (fun _ ->
         let r =
           Ringbuffer.create (ringbuffer_coeff#get * samples_per_frame)
         in
           (try Jack.Ringbuffer.mlock r with _ -> ());
           r
      )

  val mutable port = [||]

  val sample_converters =
    Array.init (Array.length port_names)
      (fun _ -> Audio_converter.Samplerate.create 1)

  method resample i ratio b ofs len =
   let conv = sample_converters.(i) in
   let ret =
     Audio_converter.Samplerate.resample conv ratio [|b|] ofs len
   in
   ret.(0)

  method output_get_ready =
    let c = client () in
      port <-
      Array.mapi
        (fun i pn ->
           let p =
             Jack.Client.register_port
               c pn "32 bit float mono audio"
               [if mode=`Input then Jack.Port.Input else Jack.Port.Output] 0
           in
             add_ringbuffer_callback
               (p, ring.(i),
                if mode=`Input then Jack.Client.Write else Jack.Client.Read);
             p
        )
        port_names
end

class input ~kind ~clock_safe port_names =
  let samples_per_second = Lazy.force Frame.audio_rate in
object (self)
  inherit Source.active_source kind as super
  inherit base ~kind port_names `Input

  method set_clock =
    super#set_clock ;
    if clock_safe then
      let clock = get_clock () in
        Clock.unify self#clock (Clock.create_known (clock:>Clock.clock)) ;
        (* TODO in the future we should use the Output class to have
         * a start/stop behavior; until then we register once for all,
         * which is a quick but dirty solution. *)
        clock#register_blocking_source

  method output = if AFrame.is_partial memo then self#get_frame memo

  (* TODO: check that we are using the right values
   * (i.e. !Fmt.samples_per_frame vs Array.length dest.(0), etc) *)
  method get_frame ab =
    activate () ;
    (* [ab] should be [memo], a fresh buffer to fill. *)
    assert (0 = AFrame.position ab) ;
    AFrame.add_break ab samples_per_frame ;
    let dest = AFrame.content_of_type ~channels ab 0 in
      (* TODO: proper error *)
      assert (Array.length port_names <= Array.length dest);

      for chan = 0 to Array.length port_names - 1 do
        let coef =
          float samples_per_second /.
          float (Jack.Client.get_sample_rate (client ()))
   
        in
        let buflen =
          if coef = 1. then
            Array.length dest.(chan)
          else
            int_of_float (ceil (float (Array.length dest.(chan)) /. coef))
        in
        let wait_for_data () =
          (* Ugly synchronization *)
          let delayed = ref 0. in
            while Ringbuffer.read_space ring.(chan) < buflen do
              Thread.delay 0.01;
              delayed := !delayed +. 0.01;
              if !delayed >= 1. then
                (
                  self#log#f 3 "No data for 1 sec, waiting...";
                  delayed := 0.
                )
            done
        in

        wait_for_data ();

        (* Throw data if there's too much... *)
        let dropped = ref 0 in
        let samplerate = samples_per_second in
        while
          Ringbuffer.read_space ring.(chan) >
          (ringbuffer_coeff#get - 2) * buflen
        do
          let len = Ringbuffer.read_space ring.(chan) - buflen in
          let tmp = Array.make len 0. in
          let n = Ringbuffer.read ring.(chan) tmp 0 len in
            self#log#f 3 "Dropping %d samples from the ringbuffer." n;
            dropped := !dropped + n;
            if !dropped >= samplerate then
              (
                self#log#f 3 "Dropped too many samples (>= %d), reseting..."
                  samplerate;
                dropped := 0;
                reset ();
                wait_for_data ()
              )
        done;

        (* Get some float samples and convert them. *)
        let buf = Array.make buflen 0. in
        let n =
          let n = Ringbuffer.read ring.(chan) buf 0 buflen in
            if n <> buflen then
              log#f 2 "Port %S: read %d < %d"
                port_names.(chan) n buflen;
            n
        in
        (* Resample data. *)
        let buf =
          if coef = 1. then buf else self#resample chan coef buf 0 n
        in
        let buflen = Array.length buf in
        let chanlen = Array.length dest.(chan) in
        let buflen = min buflen chanlen in
          Array.blit buf 0 dest.(chan) 0 buflen;
          (* Reasonable value for remaining samples. *)
          for i = buflen to chanlen - 1 do
            dest.(chan).(i) <- dest.(chan).(buflen-1)
          done;

          (* Renormalize if multiple ports are connected. *)
          let p = Jack.Port.connected port.(chan) in
          let p = if p = 0 then 1. else float p in
            if p <> 1. then
              for i = 0 to chanlen - 1 do
                dest.(chan).(i) <- dest.(chan).(i) /. p ;
              done;
      done
end

class output ~kind ~clock_safe port_names val_source =
  let source = Lang.to_source val_source in
  let samples_per_second = Lazy.force Frame.audio_rate in
object (self)

  initializer
    (* We need the source to be infallible. *)
    if source#stype <> Source.Infallible then
      raise (Lang.Invalid_value (val_source, "That source is fallible"))

  inherit Source.active_operator kind [source] as super
  inherit base ~kind port_names `Output

  method set_clock =
    super#set_clock ;
    if clock_safe then
      let clock = get_clock () in
        Clock.unify self#clock (Clock.create_known (clock:>Clock.clock)) ;
        (* TODO in the future we should use the Output class to have
         * a start/stop behavior; until then we register once for all,
         * which is a quick but dirty solution. *)
        clock#register_blocking_source

  method get_frame ab = source#get ab

  method output =
    (* Pull the stream until we get a full buffer. *)
    (* TODO: is it really necessary? *)
    while AFrame.is_partial memo do
      source#get memo
    done ;
    let s = AFrame.content memo 0 in
      (* TODO: proper error *)
      assert (Array.length port_names <= Array.length s);
      activate () ;

      for chan = 0 to Array.length port_names - 1 do
        let buf =
          self#resample chan 
            (float (Jack.Client.get_sample_rate (client ())) /.
             float samples_per_second)
            s.(chan)
            0
            (Array.length s.(chan))
        in
        let buflen = Array.length buf in
        while Ringbuffer.write_space ring.(chan) < buflen do
          Thread.delay 0.01
        done ;
        let n = Ringbuffer.write ring.(chan) buf 0 buflen in
          if n <> buflen then
            log#f 2 "Port %S: wrote %d < %d"
              port_names.(chan) n buflen
      done

end

let rec get_default_ports name n =
  if n = 0 then [] else
    (Lang.string (name ^ "_" ^ string_of_int (n-1))) ::
    (get_default_ports name (n-1))

let get_default_ports name =
  (List.rev (get_default_ports name (Lazy.force Frame.audio_channels)))

let () =
  let k = Lang.kind_type_of_kind_format ~fresh:1 Lang.audio_any in
  Lang.add_operator "input.jack.legacy"
    ~kind:(Lang.Unconstrained k)
    ~category:Lang.Input
    ~flags:[Lang.Deprecated;Lang.Hidden]
    ~descr:"Deprecated jack input."
    [
      "clock_safe",
        Lang.bool_t, Some (Lang.bool true),
        Some "Force the use of the dedicated Jack clock" ;
      "ports", Lang.list_t Lang.string_t, Some (Lang.list Lang.string_t []),
        Some "Port names." ;
    ]
    (fun p kind ->
       let ports = Lang.to_list (List.assoc "ports" p) in
       let ports =
         if ports = [] then
           get_default_ports "input"
         else
           ports
       in
       let ports = List.map Lang.to_string ports in
       let ports = Array.of_list ports in
       let clock_safe = Lang.to_bool (List.assoc "clock_safe" p) in
         ((new input ~kind ~clock_safe ports):>Source.source)) ;

  let k =
    Lang.kind_type_of_kind_format ~fresh:1 (Lang.any_fixed_with ~audio:1 ())
  in
  Lang.add_operator "output.jack.legacy"
    ~kind:(Lang.Unconstrained k)
    ~category:Lang.Output
    ~flags:[Lang.Deprecated;Lang.Hidden]
    ~descr:"Deprecated jack output."
    [
      "clock_safe",
        Lang.bool_t, Some (Lang.bool true),
        Some "Force the use of the dedicated Jack clock" ;
      "ports", Lang.list_t Lang.string_t, Some (Lang.list Lang.string_t []),
        Some "Port names." ;
      "", Lang.source_t k, None, None
    ]
    (fun p kind ->
       let ports = Lang.to_list (List.assoc "ports" p) in
       let ports =
         if ports = [] then
           get_default_ports "input"
         else
           ports
       in
       let ports = List.map Lang.to_string ports in
       let ports = Array.of_list ports in
       let clock_safe = Lang.to_bool (List.assoc "clock_safe" p) in
       let src = List.assoc "" p in
         ((new output ~kind ~clock_safe ports src):>Source.source))
