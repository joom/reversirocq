(** * Reversirocq game logic and rendering.

    A Reversi game written in Rocq, extracted to C++ via Crane and
    rendered with SDL2. The underlying rules and alpha-beta AI come
    directly from [GameTrees.Reversi]. *)

From Corelib Require Import PrimString.
From Stdlib Require Import Lists.List.
Import ListNotations.
From Stdlib Require Import Bool.
From Stdlib Require Import Strings.String Strings.Ascii.
From Stdlib Require Import ZArith.
From Crane Require Import Mapping.NatIntStd.
From Crane Require Import Mapping.Std Monads.ITree.
From Crane Require Extraction.
From CraneSDL2 Require Import SDL.

Local Open Scope pstring_scope.
Local Open Scope itree_scope.

From GameTrees Require Import Reversi.

(** Namespace containing the pure state machine, rendering, and extracted loop. *)
Module Reversirocq.

Import ITreeNotations.

(** A board coordinate. *)
Record position : Type := mkPos { prow : nat; pcol : nat }.

(** Player-selectable AI difficulty. Higher levels search more plies with the
    same alpha-beta evaluator. *)
Inductive difficulty : Type :=
| easy
| normal
| hard
| expert
| master.

(** Alpha-beta search depth for each difficulty. *)
Definition difficulty_depth (d : difficulty) : nat :=
  match d with
  | easy => 1
  | normal => 2
  | hard => 3
  | expert => 4
  | master => 5
  end.

(** Width bound used by all Reversi AI levels. Reversi has at most 64 board
    placements, so this keeps all legal children visible to the search. *)
Definition difficulty_width (_ : difficulty) : nat := 64.

(** SDL-facing game state wrapping the formal Reversi game. *)
Record game_state : Type := mkState {
  gs_core : Reversi.game;
  gs_cursor : position;
  gs_cursor_visible : bool;
  gs_difficulty : difficulty
}.

(** Board dimensions. *)
Definition board_size : nat := 8.
Definition cell_size : nat := 78.
Definition board_pixel_size : nat := board_size * cell_size.
Definition status_height : nat := 132.
Definition win_width : nat := board_pixel_size.
Definition win_height : nat := board_pixel_size + status_height.
Definition frame_ms : nat := 16.

(** Insets used by the renderer. *)
Definition cell_inset : nat := 3.
Definition disk_radius : nat := 28.
Definition hint_radius : nat := 6.

(** Asset path for the placement tap sound. *)
Definition snd_tap : PrimString.string := "assets/tap.mp3".

(** Initial SDL-facing game state. *)
Definition initial_state : game_state :=
  mkState Reversi.reversi_init (mkPos 3 2) false normal.

(** Replace the cursor fields. *)
Definition set_cursor_visible (p : position) (visible : bool) (gs : game_state)
  : game_state :=
  mkState (gs_core gs) p visible (gs_difficulty gs).

(** Replace only the core game. *)
Definition set_core (g : Reversi.game) (gs : game_state) : game_state :=
  mkState g (gs_cursor gs) (gs_cursor_visible gs) (gs_difficulty gs).

(** Replace only the selected AI difficulty. *)
Definition set_difficulty (d : difficulty) (gs : game_state) : game_state :=
  mkState (gs_core gs) (gs_cursor gs) (gs_cursor_visible gs) d.

(** Boolean equality on positions. *)
Definition pos_eqb (p1 p2 : position) : bool :=
  Nat.eqb (prow p1) (prow p2) && Nat.eqb (pcol p1) (pcol p2).

(** Extract a board cell from the game-trees representation. *)
Definition get_cell (g : Reversi.game) (row col : nat) : Reversi.cell :=
  Reversi.get_cell (Reversi.board_of g) (Reversi.pos_of row col).

(** Count total pieces on the board. *)
Definition total_pieces (g : Reversi.game) : nat :=
  Reversi.count_pieces (Reversi.board_of g) Reversi.black +
  Reversi.count_pieces (Reversi.board_of g) Reversi.white.

(** Map a mouse position to a board coordinate. *)
Definition mouse_board_pos (mp : nat * nat) : option position :=
  let '(mx, my) := mp in
  if Nat.ltb mx board_pixel_size && Nat.ltb my board_pixel_size
  then Some (mkPos (Nat.div my cell_size) (Nat.div mx cell_size))
  else None.

(** Update the hover cursor from the current mouse location. *)
Definition sync_cursor_with_mouse (mp : nat * nat) (gs : game_state) : game_state :=
  match mouse_board_pos mp with
  | Some p => set_cursor_visible p true gs
  | None => set_cursor_visible (gs_cursor gs) false gs
  end.

(** Clamp one step upward/downward. *)
Definition move_cursor_row (up : bool) (p : position) : position :=
  if up
  then mkPos (Nat.pred (prow p)) (pcol p)
  else mkPos (Nat.min (S (prow p)) (Nat.pred board_size)) (pcol p).

(** Clamp one step left/right. *)
Definition move_cursor_col (left : bool) (p : position) : position :=
  if left
  then mkPos (prow p) (Nat.pred (pcol p))
  else mkPos (prow p) (Nat.min (S (pcol p)) (Nat.pred board_size)).

(** Set the keyboard cursor visible and updated. *)
Definition map_cursor (f : position -> position) (gs : game_state) : game_state :=
  set_cursor_visible (f (gs_cursor gs)) true gs.

(** Whether the current turn belongs to the user. *)
Definition user_turn (g : Reversi.game) : bool :=
  Reversi.player_is_black (Reversi.turn_of g).

(** Whether the game is still in progress. *)
Definition game_ongoing (g : Reversi.game) : bool :=
  match Reversi.get_result g with
  | Reversi.ongoing => true
  | _ => false
  end.

(** Whether a retained event asks the game to quit while the AI is thinking. *)
Definition event_requests_quit (ev : sdl_event) : bool :=
  match ev with
  | EventQuit => true
  | EventKeyDown KeyEscape => true
  | _ => false
  end.

(** Whether any retained event asks the game to quit. *)
Fixpoint events_request_quit (events : list sdl_event) : bool :=
  match events with
  | [] => false
  | ev :: rest => orb (event_requests_quit ev) (events_request_quit rest)
  end.

(** Drain events while the AI is thinking, discarding everything except quit and
    Escape. *)
Definition drain_thinking_events : itree sdlE bool :=
  events <- sdl_drain_events sdl_keep_quit_and_escape ;;
  Ret (events_request_quit events).

(** SDL-responsive variant of the executable Reversi evaluator.

    It follows [Reversi.executable_eval_game], but drains SDL before each child
    evaluation so deeper difficulty levels do not make macOS show a spinning
    wait cursor while the alpha-beta search is running. *)
Fixpoint responsive_eval_game (depth width alpha beta : nat)
    (g : Reversi.game) : itree sdlE (bool * nat) :=
  match depth with
  | O => Ret (false, Reversi.heuristic_score g)
  | S depth' =>
    match Reversi.get_result g with
    | Reversi.won_by _ | Reversi.draw => Ret (false, Reversi.heuristic_score g)
    | Reversi.ongoing =>
      let children := Reversi.executable_reversi_next g in
      match Reversi.next_turn g with
      | Reversi.black =>
        let fix eval_max (fuel : nat) (remaining : list Reversi.game)
            (alpha0 beta0 : nat) : itree sdlE (bool * nat) :=
          match fuel, remaining with
          | O, _ => Ret (false, alpha0)
          | _, [] => Ret (false, alpha0)
          | S fuel', child :: rest =>
              quit_drain <- drain_thinking_events ;;
              res <- responsive_eval_game depth' width alpha0 beta0 child ;;
              let '(quit_child, v) := res in
              let quit := orb quit_drain quit_child in
              let best := Nat.max alpha0 v in
              if quit then Ret (true, best)
              else if Nat.leb beta0 best then Ret (false, best)
              else eval_max fuel' rest best beta0
          end in
        eval_max width children alpha beta
      | Reversi.white =>
        let fix eval_min (fuel : nat) (remaining : list Reversi.game)
            (alpha0 beta0 : nat) : itree sdlE (bool * nat) :=
          match fuel, remaining with
          | O, _ => Ret (false, beta0)
          | _, [] => Ret (false, beta0)
          | S fuel', child :: rest =>
              quit_drain <- drain_thinking_events ;;
              res <- responsive_eval_game depth' width alpha0 beta0 child ;;
              let '(quit_child, v) := res in
              let quit := orb quit_drain quit_child in
              let best := Nat.min beta0 v in
              if quit then Ret (true, best)
              else if Nat.leb best alpha0 then Ret (false, best)
              else eval_min fuel' rest alpha0 best
          end in
        eval_min width children alpha beta
      end
    end
  end.

(** Score a position with the SDL-responsive executable evaluator. *)
Definition responsive_co_score_game (depth width : nat) (g : Reversi.game)
    : itree sdlE (bool * nat) :=
  responsive_eval_game depth width 0 1000 g.

(** Choose the best child while periodically pumping SDL events. *)
Fixpoint responsive_choose_best_game (depth width : nat) (p : Reversi.player)
    (best : Reversi.game) (best_score : nat) (rest : list Reversi.game)
    : itree sdlE (bool * Reversi.game) :=
  match rest with
  | [] => Ret (false, best)
  | g :: rest' =>
    quit_drain <- drain_thinking_events ;;
    res <- responsive_co_score_game depth width g ;;
    let '(quit_child, s) := res in
    let quit := orb quit_drain quit_child in
    if quit then Ret (true, best)
    else if Reversi.prefers p best_score s
    then responsive_choose_best_game depth width p g s rest'
    else responsive_choose_best_game depth width p best best_score rest'
  end.

(** Compute an AI move with SDL event pumping during the alpha-beta search. *)
Definition responsive_ai_move (depth width : nat) (g : Reversi.game)
    : itree sdlE (bool * option Reversi.game) :=
  match Reversi.executable_reversi_next g with
  | [] => Ret (false, None)
  | first :: rest =>
    first_res <- responsive_co_score_game depth width first ;;
    let '(quit_first, first_score) := first_res in
    if quit_first then Ret (true, None)
    else
      best_res <- responsive_choose_best_game depth width (Reversi.next_turn g)
                    first first_score rest ;;
      let '(quit_best, best) := best_res in
      Ret (quit_best, if quit_best then None else Some best)
  end.

(** Resolve AI turns and forced player passes until control returns to the user
    or the game ends. The fuel is generous because Reversi can force two
    consecutive passes near the end of the game. *)
Fixpoint resolve_automatic_turns (fuel : nat) (d : difficulty)
    (g : Reversi.game) : itree sdlE (bool * Reversi.game) :=
  match fuel with
  | 0 => Ret (false, g)
  | S fuel' =>
    match Reversi.get_result g with
    | Reversi.ongoing =>
      if user_turn g then
        match Reversi.valid_positions (Reversi.board_of g) Reversi.black with
        | [] => resolve_automatic_turns fuel' d (Reversi.executable_pass g)
        | _ => Ret (false, g)
        end
      else
        ai_res <- responsive_ai_move
                    (difficulty_depth d) (difficulty_width d) g ;;
        let '(quit, ai) := ai_res in
        if quit then Ret (true, g)
        else
          match ai with
          | Some g' => resolve_automatic_turns fuel' d g'
          | None => Ret (false, g)
          end
    | _ => Ret (false, g)
    end
  end.

(** Apply a user move from a concrete board coordinate, then resolve the AI
    reply and any forced passes. *)
Definition apply_user_move_at (p : position) (gs : game_state) : game_state :=
  let g := gs_core gs in
  match Reversi.get_result g with
  | Reversi.ongoing =>
    if user_turn g then
      if Reversi.is_valid_move (Reversi.board_of g) Reversi.black (prow p) (pcol p)
      then
        let g' := Reversi.executable_place g (prow p) (pcol p) in
        set_core g' (set_cursor_visible p true gs)
      else set_cursor_visible p true gs
    else gs
  | _ => gs
  end.

(** Trigger a move at the current cursor position. *)
Definition play_at_cursor (gs : game_state) : game_state :=
  apply_user_move_at (gs_cursor gs) gs.

(** Restart the game from the initial position. *)
Definition restart_state (_ : game_state) : game_state := initial_state.

(** Handle directional keyboard movement. *)
Definition handle_direction_key (key : sdl_key) (gs : game_state) : game_state :=
  match key with
  | KeyUp | KeyW => map_cursor (move_cursor_row true) gs
  | KeyDown | KeyS => map_cursor (move_cursor_row false) gs
  | KeyLeft | KeyA => map_cursor (move_cursor_col true) gs
  | KeyRight | KeyD => map_cursor (move_cursor_col false) gs
  | _ => gs
  end.

(** Handle a key press. *)
Definition handle_key_down (key : sdl_key) (gs : game_state) : bool * game_state :=
  match key with
  | KeyEscape | KeyQ => (true, gs)
  | KeyR => (false, restart_state gs)
  | KeyDigit1 => (false, set_difficulty easy gs)
  | KeyDigit2 => (false, set_difficulty normal gs)
  | KeyDigit3 => (false, set_difficulty hard gs)
  | KeyDigit4 => (false, set_difficulty expert gs)
  | KeyDigit5 => (false, set_difficulty master gs)
  | KeySpace | KeyReturn => (false, play_at_cursor gs)
  | _ => (false, handle_direction_key key gs)
  end.

(** Handle a mouse-button press. *)
Definition handle_mouse_button_down (button : sdl_mouse_button)
    (mp : nat * nat) (gs : game_state) : bool * game_state :=
  match button with
  | MouseLeft =>
    match mouse_board_pos mp with
    | Some p => (false, apply_user_move_at p gs)
    | None => (false, gs)
    end
  | _ => (false, gs)
  end.

(** Translate an SDL event to a quit flag and pure next state. *)
Definition handle_event (ev : sdl_event) (gs : game_state) : bool * game_state :=
  match ev with
  | EventNone => (false, gs)
  | EventQuit => (true, gs)
  | EventKeyDown key => handle_key_down key gs
  | EventKeyUp _ => (false, gs)
  | EventMouseMotion mp => (false, sync_cursor_with_mouse mp gs)
  | EventMouseButtonDown button mp => handle_mouse_button_down button mp gs
  | EventMouseButtonUp _ _ => (false, gs)
  end.

(** Pixel helpers. *)
Definition cell_left (col : nat) : nat := col * cell_size.
Definition cell_top (row : nat) : nat := row * cell_size.
Definition cell_center_x (col : nat) : nat := cell_left col + Nat.div cell_size 2.
Definition cell_center_y (row : nat) : nat := cell_top row + Nat.div cell_size 2.

(** Absolute difference on naturals. *)
Definition abs_diff (a b : nat) : nat :=
  if Nat.leb a b then b - a else a - b.

(** Conditionally draw one point. Kept as a separate helper so extraction avoids
    a unit-valued C++ lambda around the SDL call. *)
Definition draw_point_when (cond : bool) (ren : sdl_renderer) (x y : nat)
  : itree sdlE unit :=
  if cond then sdl_draw_point ren x y else Ret tt.

(** Conditionally fill one rectangle. *)
Definition fill_rect_when (cond : bool) (ren : sdl_renderer)
    (x y w h : nat) : itree sdlE unit :=
  if cond then sdl_fill_rect ren x y w h else Ret tt.

(** Set the disk shadow color. *)
Definition set_disk_shadow_color (ren : sdl_renderer) (is_black : bool)
  : itree sdlE unit :=
  if is_black
  then sdl_set_draw_color ren 124 132 138
  else sdl_set_draw_color ren 68 76 82.

(** Set the disk body color. *)
Definition set_disk_body_color (ren : sdl_renderer) (is_black : bool)
  : itree sdlE unit :=
  if is_black
  then sdl_set_draw_color ren 22 24 27
  else sdl_set_draw_color ren 239 239 232.

(** Set the disk highlight color. *)
Definition set_disk_highlight_color (ren : sdl_renderer) (is_black : bool)
  : itree sdlE unit :=
  if is_black
  then sdl_set_draw_color ren 92 101 108
  else sdl_set_draw_color ren 255 255 255.

(** Draw a filled disk row using local bounding-box offsets for the distance
    check and screen coordinates for the point placement. *)
Fixpoint filled_circle_row (ren : sdl_renderer) (cx y radius dy dx count : nat)
  : itree sdlE unit :=
  match count with
  | 0 => Ret tt
  | S count' =>
    let dy0 := abs_diff dy radius in
    let dx0 := abs_diff dx radius in
    let dist_sq := dx0 * dx0 + dy0 * dy0 in
    draw_point_when (Nat.leb dist_sq (radius * radius))
      ren (cx - radius + dx) y ;;
    filled_circle_row ren cx y radius dy (S dx) count'
  end.

(** Draw a filled circle centered at [(cx, cy)]. *)
Fixpoint filled_circle_rows (ren : sdl_renderer) (cx cy radius dy count : nat)
  : itree sdlE unit :=
  match count with
  | 0 => Ret tt
  | S count' =>
    let y := cy - radius + dy in
    filled_circle_row ren cx y radius dy 0 (radius + radius + 1) ;;
    filled_circle_rows ren cx cy radius (S dy) count'
  end.

Definition draw_filled_circle (ren : sdl_renderer) (cx cy radius : nat)
  : itree sdlE unit :=
  filled_circle_rows ren cx cy radius 0 (radius + radius + 1).

(** Bitmap font utilities copied from the other games for status text. *)
Definition glyph_row_data (g row : nat) : nat :=
  nth row (nth g
    [ [14;17;19;21;25;17;14]
    ; [4;12;4;4;4;4;14]
    ; [14;17;1;6;8;16;31]
    ; [14;17;1;6;1;17;14]
    ; [2;6;10;18;31;2;2]
    ; [31;16;30;1;1;17;14]
    ; [6;8;16;30;17;17;14]
    ; [31;1;2;4;8;8;8]
    ; [14;17;17;14;17;17;14]
    ; [14;17;17;15;1;2;12]
    ; [0;0;0;0;0;0;0]
    ; [4;10;17;17;31;17;17]
    ; [30;17;17;30;17;17;30]
    ; [14;17;16;16;16;17;14]
    ; [28;18;17;17;17;18;28]
    ; [31;16;16;30;16;16;31]
    ; [31;16;16;30;16;16;16]
    ; [14;17;16;23;17;17;14]
    ; [17;17;17;31;17;17;17]
    ; [14;4;4;4;4;4;14]
    ; [7;2;2;2;2;18;12]
    ; [17;18;20;24;20;18;17]
    ; [16;16;16;16;16;16;31]
    ; [17;27;21;17;17;17;17]
    ; [17;25;21;19;17;17;17]
    ; [14;17;17;17;17;17;14]
    ; [30;17;17;30;16;16;16]
    ; [14;17;17;17;21;18;13]
    ; [30;17;17;30;20;18;17]
    ; [14;17;16;14;1;17;14]
    ; [31;4;4;4;4;4;4]
    ; [17;17;17;17;17;17;14]
    ; [17;17;17;17;10;10;4]
    ; [17;17;17;21;21;21;10]
    ; [17;17;10;4;10;17;17]
    ; [17;17;10;4;4;4;4]
    ; [31;1;2;4;8;16;31]
    ; [0;4;4;0;4;4;0]
    ; [1;2;4;8;16;0;0]
    ; [0;0;14;1;15;17;15]
    ; [16;16;22;25;17;17;30]
    ; [0;0;14;16;16;17;14]
    ; [1;1;13;19;17;17;15]
    ; [0;0;14;17;31;16;14]
    ; [6;8;30;8;8;8;8]
    ; [0;0;15;17;15;1;14]
    ; [16;16;22;25;17;17;17]
    ; [4;0;12;4;4;4;14]
    ; [2;0;6;2;2;18;12]
    ; [16;16;18;20;24;20;18]
    ; [12;4;4;4;4;4;14]
    ; [0;0;26;21;21;21;21]
    ; [0;0;22;25;17;17;17]
    ; [0;0;14;17;17;17;14]
    ; [0;0;30;17;30;16;16]
    ; [0;0;13;19;15;1;1]
    ; [0;0;22;25;16;16;16]
    ; [0;0;15;16;14;1;30]
    ; [8;8;30;8;8;9;6]
    ; [0;0;17;17;17;19;13]
    ; [0;0;17;17;17;10;4]
    ; [0;0;17;17;21;21;10]
    ; [0;0;17;10;4;10;17]
    ; [0;0;17;17;15;1;14]
    ; [0;0;31;2;4;8;31]
    ] []) 0.

Fixpoint draw_glyph_row (ren : sdl_renderer) (sx sy row_bits dx count scale : nat)
  : itree sdlE unit :=
  match count with
  | 0 => Ret tt
  | S count' =>
    fill_rect_when (Nat.testbit row_bits (4 - dx))
      ren (sx + dx * scale) sy scale scale ;;
    draw_glyph_row ren sx sy row_bits (S dx) count' scale
  end.

Fixpoint draw_glyph_rows (ren : sdl_renderer) (sx sy g row count scale : nat)
  : itree sdlE unit :=
  match count with
  | 0 => Ret tt
  | S count' =>
    draw_glyph_row ren sx (sy + row * scale) (glyph_row_data g row) 0 5 scale ;;
    draw_glyph_rows ren sx sy g (S row) count' scale
  end.

Definition draw_one_glyph (ren : sdl_renderer) (sx sy g scale : nat)
  : itree sdlE unit :=
  draw_glyph_rows ren sx sy g 0 7 scale.

Definition ascii_to_glyph (a : ascii) : nat :=
  let n := nat_of_ascii a in
  if Nat.leb 48 n && Nat.leb n 57 then n - 48
  else if Nat.eqb n 32 then 10
  else if Nat.leb 65 n && Nat.leb n 90 then 11 + (n - 65)
  else if Nat.eqb n 58 then 37
  else if Nat.eqb n 47 then 38
  else if Nat.leb 97 n && Nat.leb n 122 then 39 + (n - 97)
  else 10.

Fixpoint string_to_glyphs (s : String.string) : list nat :=
  match s with
  | EmptyString => []
  | String a rest => ascii_to_glyph a :: string_to_glyphs rest
  end.

Fixpoint draw_glyphs (ren : sdl_renderer) (sx sy scale : nat) (glyphs : list nat)
  : itree sdlE unit :=
  match glyphs with
  | [] => Ret tt
  | g :: rest =>
    draw_one_glyph ren sx sy g scale ;;
    draw_glyphs ren (sx + 6 * scale) sy scale rest
  end.

Fixpoint draw_number_digits (ren : sdl_renderer) (sx sy scale : nat)
    (digits : list nat) : itree sdlE unit :=
  match digits with
  | [] => Ret tt
  | d :: rest =>
    draw_one_glyph ren sx sy d scale ;;
    draw_number_digits ren (sx + 6 * scale) sy scale rest
  end.

Definition draw_number (ren : sdl_renderer) (n sx sy scale : nat) : itree sdlE unit :=
  draw_number_digits ren sx sy scale (nat_digit_list n).

Definition draw_text (ren : sdl_renderer) (sx sy scale : nat) (msg : String.string)
  : itree sdlE unit :=
  draw_glyphs ren sx sy scale (string_to_glyphs msg).

(** Render one board cell background. *)
Definition draw_board_cell (ren : sdl_renderer) (row col : nat) : itree sdlE unit :=
  let x := cell_left col in
  let y := cell_top row in
  let '(r, g, b) :=
    if Nat.even (row + col)
    then (34, 108, 73)
    else (28, 94, 63) in
  sdl_set_draw_color ren r g b ;;
  sdl_fill_rect ren x y cell_size cell_size ;;
  sdl_set_draw_color ren 16 55 37 ;;
  sdl_fill_rect ren x y cell_size 1 ;;
  sdl_fill_rect ren x y 1 cell_size ;;
  Ret tt.

(** Render a legal-move hint dot. *)
Definition draw_hint (ren : sdl_renderer) (row col : nat) : itree sdlE unit :=
  sdl_set_draw_color ren 232 198 77 ;;
  draw_filled_circle ren (cell_center_x col) (cell_center_y row) hint_radius.

(** Render a black or white disk with a light highlight. *)
Definition draw_disk (ren : sdl_renderer) (row col : nat) (is_black : bool)
  : itree sdlE unit :=
  let cx := cell_center_x col in
  let cy := cell_center_y row in
  let outer := disk_radius in
  let inner := disk_radius - 4 in
  set_disk_shadow_color ren is_black ;;
  draw_filled_circle ren cx cy outer ;;
  set_disk_body_color ren is_black ;;
  draw_filled_circle ren cx cy inner ;;
  set_disk_highlight_color ren is_black ;;
  draw_filled_circle ren (cx - 10) (cy - 10) 6.

(** Render the cursor frame if active. *)
Definition draw_cursor (ren : sdl_renderer) (p : position) (valid_move : option bool)
  : itree sdlE unit :=
  let x := cell_left (pcol p) in
  let y := cell_top (prow p) in
  let '(r, g, b) :=
    match valid_move with
    | Some true => (72, 201, 111)
    | Some false => (212, 74, 74)
    | None => (246, 214, 80)
    end in
  sdl_set_draw_color ren r g b ;;
  sdl_fill_rect ren x y cell_size 3 ;;
  sdl_fill_rect ren x y 3 cell_size ;;
  sdl_fill_rect ren x (y + cell_size - 3) cell_size 3 ;;
  sdl_fill_rect ren (x + cell_size - 3) y 3 cell_size ;;
  Ret tt.

(** Draw the cursor only when it is visible. *)
Definition draw_cursor_when (visible : bool) (ren : sdl_renderer)
    (p : position) (valid_move : option bool) : itree sdlE unit :=
  if visible then draw_cursor ren p valid_move else Ret tt.

(** Draw one row of the board. *)
Fixpoint draw_row (ren : sdl_renderer) (g : Reversi.game) (row col : nat)
    (cells : list Reversi.cell) : itree sdlE unit :=
  match cells with
  | [] => Ret tt
  | c :: rest =>
    draw_board_cell ren row col ;;
    (if Reversi.cell_is_empty c then
       if user_turn g && Reversi.is_valid_move (Reversi.board_of g) Reversi.black row col
       then draw_hint ren row col
     else Ret tt
     else draw_disk ren row col (Reversi.player_is_black (Reversi.cell_player c))) ;;
    draw_row ren g row (S col) rest
  end.

(** Draw all board rows. *)
Fixpoint draw_rows (ren : sdl_renderer) (g : Reversi.game) (row : nat)
    (rows : list (list Reversi.cell)) : itree sdlE unit :=
  match rows with
  | [] => Ret tt
  | cells :: rest =>
    draw_row ren g row 0 cells ;;
    draw_rows ren g (S row) rest
  end.

(** Convert the flat 64-cell board into 8 rows for drawing. *)
Definition board_rows (g : Reversi.game) : list (list Reversi.cell) :=
  map (fun r => map (fun c => get_cell g r c) (seq 0 board_size)) (seq 0 board_size).

(** Short status message summarizing the game state. *)
Definition status_message (g : Reversi.game) : String.string :=
  match Reversi.result_code g with
  | 0 => if user_turn g then "Your turn"%string else "Computer thinking"%string
  | 1 => "You win"%string
  | 2 => "Computer wins"%string
  | _ => "Draw"%string
  end.

(** Status text for the currently selected AI level. *)
Definition difficulty_message (d : difficulty) : String.string :=
  match d with
  | easy => "AI easy 1 ply      keys 12345"%string
  | normal => "AI normal 2 ply    keys 12345"%string
  | hard => "AI hard 3 ply      keys 12345"%string
  | expert => "AI expert 4 ply    keys 12345"%string
  | master => "AI master 5 ply    keys 12345"%string
  end.

(** Helper label renderer. *)
Definition draw_label_number (ren : sdl_renderer) (label : String.string) (n x y : nat)
  : itree sdlE unit :=
  sdl_set_draw_color ren 31 43 52 ;;
  draw_text ren x y 2 label ;;
  draw_number ren n (x + 84) y 2.

(** Draw the bottom status area. *)
Definition draw_status_bar (ren : sdl_renderer) (gs : game_state) : itree sdlE unit :=
  let top := board_pixel_size in
  let g := gs_core gs in
  sdl_set_draw_color ren 227 219 198 ;;
  sdl_fill_rect ren 0 top win_width status_height ;;
  draw_label_number ren "Black"%string
    (Reversi.count_pieces (Reversi.board_of g) Reversi.black) 18 (top + 12) ;;
  draw_label_number ren "White"%string
    (Reversi.count_pieces (Reversi.board_of g) Reversi.white) 226 (top + 12) ;;
  sdl_set_draw_color ren 31 43 52 ;;
  draw_text ren 18 (top + 44) 2 (status_message g) ;;
  draw_text ren 18 (top + 74) 2 (difficulty_message (gs_difficulty gs)) ;;
  draw_text ren 18 (top + 100) 2 "Click    R restart    Esc quit"%string.

(** Render a full frame. *)
Definition render_frame (ren : sdl_renderer) (gs : game_state) : itree sdlE unit :=
  let g := gs_core gs in
  let cursor_validity :=
    if user_turn g
    then Some (Reversi.is_valid_move (Reversi.board_of g) Reversi.black
                  (prow (gs_cursor gs)) (pcol (gs_cursor gs)))
    else None in
  sdl_set_draw_color ren 92 60 36 ;;
  sdl_clear ren ;;
  draw_rows ren g 0 (board_rows g) ;;
  draw_cursor_when (gs_cursor_visible gs) ren (gs_cursor gs) cursor_validity ;;
  draw_status_bar ren gs ;;
  sdl_present ren ;;
  Ret tt.

(** Loop state. *)
Record loop_state : Type := mkLoop {
  ls_game : game_state
}.

(** Sleep to maintain the target frame time. *)
Definition delay_when_needed (elapsed : nat) : itree sdlE unit :=
  if Nat.ltb elapsed frame_ms
  then sdl_delay (frame_ms - elapsed)
  else Ret tt.

Definition frame_delay (frame_start : nat) : itree sdlE unit :=
  now2 <- sdl_get_ticks ;;
  let elapsed := now2 - frame_start in
  delay_when_needed elapsed ;;
  Ret tt.

(** Play the placement sound if new pieces appeared this frame. *)
Definition play_sound_when (cond : bool) : itree sdlE unit :=
  if cond then sdl_play_sound snd_tap else Ret tt.

Definition maybe_play_sound (before after : game_state) : itree sdlE unit :=
  play_sound_when
    (Nat.ltb (total_pieces (gs_core before)) (total_pieces (gs_core after))) ;;
  Ret tt.

(** Pure input update for the frame to be presented immediately.  Automatic
    turns are resolved after presentation so the user sees the just-played disk
    and "Computer thinking" status before the AI search runs. *)
Definition frame_input_update (ev : sdl_event) (mp : nat * nat) (gs : game_state)
  : bool * game_state :=
  let gs0 := sync_cursor_with_mouse mp gs in
  handle_event ev gs0.

(** Process one frame. *)
Definition process_frame (ren : sdl_renderer) (ls : loop_state)
  : itree sdlE (bool * loop_state) :=
  frame_start <- sdl_get_ticks ;;
  ev <- sdl_poll_event ;;
  mp <- sdl_get_mouse_position ;;
  let before := ls_game ls in
  let rendered := frame_input_update ev mp before in
  let '(quit, render_gs) := rendered in
  maybe_play_sound before render_gs ;;
  render_frame ren render_gs ;;
  auto_res <- resolve_automatic_turns 6 (gs_difficulty render_gs)
                (gs_core render_gs) ;;
  let '(thinking_quit, next_core) := auto_res in
  let next_gs := set_core next_core render_gs in
  frame_delay frame_start ;;
  Ret (orb quit thinking_quit, mkLoop next_gs).

(** Initialize SDL. *)
Definition init_game : itree sdlE (sdl_window * sdl_renderer * loop_state) :=
  win <- sdl_create_window "Reversirocq" win_width win_height ;;
  ren <- sdl_create_renderer win ;;
  let gs := initial_state in
  render_frame ren gs ;;
  Ret (win, ren, mkLoop gs).

(** Release SDL resources. *)
Definition cleanup (ren : sdl_renderer) (win : sdl_window) : itree sdlE unit :=
  sdl_destroy ren win ;;
  Ret tt.

End Reversirocq.

Import Reversirocq.
Import ITreeNotations.

(** C process exit code used only at the extracted program boundary. *)
Axiom c_int : Type.
Axiom c_zero : c_int.

Crane Extract Inlined Constant c_int => "int".
Crane Extract Inlined Constant c_zero => "0".

(** Cleanup wrapper used when the game loop exits. *)
Definition exit_game (win : sdl_window) (ren : sdl_renderer) : itree sdlE unit :=
  cleanup ren win.

(** Main recursive SDL game loop. *)
CoFixpoint run_game (win : sdl_window) (ren : sdl_renderer)
                    (ls : loop_state) : itree sdlE unit :=
  res <- process_frame ren ls ;;
  let '(quit, ls') := res in
  if quit then exit_game win ren else Tau (run_game win ren ls').

(** Program entry point used by extraction. *)
Definition main : itree sdlE c_int :=
  init <- init_game ;;
  let '(win_ren, ls) := init in
  let '(win, ren) := win_ren in
  run_game win ren ls ;;
  Ret c_zero.

Crane Extraction "reversirocq" main.
