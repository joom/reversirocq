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

(** Extraction-friendly Reversi rules and alpha-beta search, adapted from the
    game-trees formalization. *)
Module GT.

Inductive player : Type := black | white.

Definition player_eqb (p1 p2 : player) : bool :=
  match p1, p2 with
  | black, black | white, white => true
  | _, _ => false
  end.

Inductive cell : Type :=
| Empty
| Filled : player -> cell.

Definition board : Type := list cell.

Record game : Type := mkGame {
  current_board : board;
  next_turn : player;
  pass_count : nat
}.

Definition other_player (p : player) : player :=
  match p with black => white | white => black end.

Definition get_cell (b : board) (pos : nat) : cell :=
  nth pos b Empty.

Fixpoint set_cell (b : board) (pos : nat) (c : cell) : board :=
  match b, pos with
  | [], _ => []
  | _ :: xs, 0 => c :: xs
  | x :: xs, S n => x :: set_cell xs n c
  end.

Definition pos_of (row col : nat) : nat := row * 8 + col.

Definition in_bounds (row col : nat) : bool :=
  (row <? 8) && (col <? 8).

Definition init_board : board :=
  let e := Empty in
  let rows_0_2 := repeat e 24 in
  let row_3 := repeat e 3 ++ [Filled white; Filled black] ++ repeat e 3 in
  let row_4 := repeat e 3 ++ [Filled black; Filled white] ++ repeat e 3 in
  let rows_5_7 := repeat e 24 in
  rows_0_2 ++ row_3 ++ row_4 ++ rows_5_7.

Definition reversi_init : game :=
  mkGame init_board black 0.

Open Scope Z_scope.

Definition direction : Type := (Z * Z)%type.

Definition all_directions : list direction :=
  [(-1,-1); (-1,0); (-1,1);
   ( 0,-1);         ( 0,1);
   ( 1,-1); ( 1,0); ( 1,1)].

  Fixpoint find_flips (b : board) (p : player)
    (row col : Z) (dr dc : Z) (acc : list nat) (fuel : nat) : list nat :=
  match fuel with
  | O => []
  | S fuel' =>
    let r := (row + dr)%Z in
    let c := (col + dc)%Z in
    if ((0 <=? r) && (r <? 8) && (0 <=? c) && (c <? 8))%Z then
      let pos := Z.to_nat (r * 8 + c)%Z in
      match get_cell b pos with
      | Filled q =>
        if player_eqb q p then acc
        else find_flips b p r c dr dc (acc ++ [pos]) fuel'
      | Empty => []
      end
    else []
  end.

Close Scope Z_scope.

Definition flips_in_direction (b : board) (p : player)
    (row col : nat) (d : direction) : list nat :=
  let '(dr, dc) := d in
  find_flips b p (Z.of_nat row) (Z.of_nat col) dr dc [] 7.

Definition all_flips (b : board) (p : player) (row col : nat) : list nat :=
  List.concat (map (flips_in_direction b p row col) all_directions).

Definition is_valid_move (b : board) (p : player) (row col : nat) : bool :=
  in_bounds row col &&
  match get_cell b (pos_of row col) with
  | Empty => negb (Nat.eqb (List.length (all_flips b p row col)) 0)
  | Filled _ => false
  end.

Definition apply_flips (b : board) (p : player) (flips : list nat) : board :=
  fold_left (fun b' pos => set_cell b' pos (Filled p)) flips b.

Definition place_piece (b : board) (p : player) (row col : nat) : board :=
  let pos := pos_of row col in
  let b' := set_cell b pos (Filled p) in
  apply_flips b' p (all_flips b p row col).

Definition all_positions : list (nat * nat) :=
  List.concat (map (fun r => map (fun c => (r, c)) (seq 0 8)) (seq 0 8)).

Definition valid_positions (b : board) (p : player) : list (nat * nat) :=
  filter (fun '(r, c) => is_valid_move b p r c) all_positions.

Inductive result : Type :=
| won_by : player -> result
| draw : result
| ongoing : result.

Definition count_pieces (b : board) (p : player) : nat :=
  List.length (filter (fun c =>
    match c with
    | Filled q => player_eqb q p
    | Empty => false
    end) b).

Definition empty_count (b : board) : nat :=
  List.length (filter (fun c => match c with Empty => true | _ => false end) b).

Definition get_result (g : game) : result :=
  let b := current_board g in
  if Nat.leb 2 (pass_count g) || Nat.eqb (empty_count b) 0 then
    let nb := count_pieces b black in
    let nw := count_pieces b white in
    if nb <? nw then won_by white
    else if nw <? nb then won_by black
    else draw
  else ongoing.

Inductive move : Type :=
| place : nat -> nat -> move
| pass : move.

Definition apply_move (g : game) (m : move) : game :=
  let b := current_board g in
  let p := next_turn g in
  match m with
  | place row col =>
    mkGame (place_piece b p row col) (other_player p) 0
  | pass =>
    mkGame b (other_player p) (S (pass_count g))
  end.

Definition moves (g : game) : list move :=
  match get_result g with
  | won_by _ | draw => []
  | ongoing =>
    match valid_positions (current_board g) (next_turn g) with
    | [] => [pass]
    | ps => map (fun '(r, c) => place r c) ps
    end
  end.

Definition corner_positions : list (nat * nat) :=
  [(0,0); (0,7); (7,0); (7,7)].

Definition count_corners (b : board) (p : player) : nat :=
  List.length (filter (fun '(r, c) =>
    match get_cell b (pos_of r c) with
    | Filled q => player_eqb q p
    | Empty => false
    end) corner_positions).

Definition clamp_score (z : Z) : nat :=
  Z.to_nat (Z.max 0 (Z.min 1000 z)).

Definition score (g : game) : nat :=
  match get_result g with
  | won_by black => 1000
  | won_by white => 0
  | draw => 500
  | ongoing =>
    let b := current_board g in
    let nb := Z.of_nat (count_pieces b black) in
    let nw := Z.of_nat (count_pieces b white) in
    let mb := Z.of_nat (List.length (valid_positions b black)) in
    let mw := Z.of_nat (List.length (valid_positions b white)) in
    let cb := Z.of_nat (count_corners b black) in
    let cw := Z.of_nat (count_corners b white) in
    clamp_score (500 + (nb - nw) * 4 + (mb - mw) * 10 + (cb - cw) * 80)
  end.

Definition alpha_min : nat := 0.
Definition beta_max : nat := 1000.
Definition search_depth : nat := 2.

CoInductive cotree : Type :=
| conode : game -> (nat -> option game) -> cotree.

Definition game_children (g : game) : list game :=
  map (apply_move g) (moves g).

Definition unfold_game_tree (g : game) : cotree :=
  conode g (fun idx =>
    match nth_error (game_children g) idx with
    | Some g' => Some g'
    | None => None
    end).

Definition cotree_root (t : cotree) : game :=
  match t with
  | conode a _ => a
  end.

Definition cotree_children (t : cotree) : nat -> option game :=
  match t with
  | conode _ kids => kids
  end.

Fixpoint eval_ab_co (depth alpha beta : nat) (t : cotree) : nat :=
  match depth with
  | 0 => score (cotree_root t)
  | S depth' =>
      let g := cotree_root t in
    match get_result g with
    | won_by _ => score g
    | draw => score g
    | ongoing =>
      match next_turn g with
      | black =>
        let fix eval_max_children (fuel idx alpha0 beta0 : nat) : nat :=
          match fuel with
          | 0 => alpha0
          | S fuel' =>
            match cotree_children t idx with
            | None => alpha0
            | Some child =>
              let v := eval_ab_co depth' alpha0 beta0 (unfold_game_tree child) in
              let best := Nat.max alpha0 v in
              if Nat.leb beta0 best then best
              else eval_max_children fuel' (S idx) best beta0
            end
          end in
        eval_max_children 64 0 alpha beta
      | white =>
        let fix eval_min_children (fuel idx alpha0 beta0 : nat) : nat :=
          match fuel with
          | 0 => beta0
          | S fuel' =>
            match cotree_children t idx with
            | None => beta0
            | Some child =>
              let v := eval_ab_co depth' alpha0 beta0 (unfold_game_tree child) in
              let best := Nat.min beta0 v in
              if Nat.leb best alpha0 then best
              else eval_min_children fuel' (S idx) alpha0 best
            end
          end in
        eval_min_children 64 0 alpha beta
      end
    end
  end.

Definition prefers (p : player) (best cand : nat) : bool :=
  match p with
  | black => Nat.leb best cand
  | white => Nat.leb cand best
  end.

Definition score_game (g : game) : nat :=
  eval_ab_co search_depth alpha_min beta_max (unfold_game_tree g).

Definition choose_step (p : player) (acc : game * nat) (g : game)
  : game * nat :=
  let '(best, best_score) := acc in
  let s := score_game g in
  if prefers p best_score s
  then (g, s)
  else (best, best_score).

Definition choose_best_game (p : player) (best : game) (best_score : nat)
    (rest : list game) : game :=
  fst (fold_left (choose_step p) rest (best, best_score)).

Definition ai_move (g : game) : option game :=
  match game_children g with
  | [] => None
  | first :: rest =>
    Some (choose_best_game (next_turn g) first (score_game first) rest)
  end.

Definition board_of (g : game) : board := current_board g.
Definition turn_of (g : game) : player := next_turn g.

Definition player_is_black (p : player) : bool := player_eqb p black.

Definition cell_is_empty (c : cell) : bool :=
  match c with
  | Empty => true
  | Filled _ => false
  end.

Definition cell_player (c : cell) : player :=
  match c with
  | Empty => black
  | Filled p => p
  end.

Definition result_code (g : game) : nat :=
  match get_result g with
  | ongoing => 0
  | won_by black => 1
  | won_by white => 2
  | draw => 3
  end.

End GT.

(** Namespace containing the pure state machine, rendering, and extracted loop. *)
Module Reversirocq.

Import ITreeNotations.

(** A board coordinate. *)
Record position : Type := mkPos { prow : nat; pcol : nat }.

(** SDL-facing game state wrapping the formal Reversi game. *)
Record game_state : Type := mkState {
  gs_core : GT.game;
  gs_cursor : position;
  gs_cursor_visible : bool
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
  mkState GT.reversi_init (mkPos 3 2) false.

(** Replace the cursor fields. *)
Definition set_cursor_visible (p : position) (visible : bool) (gs : game_state)
  : game_state :=
  mkState (gs_core gs) p visible.

(** Replace only the core game. *)
Definition set_core (g : GT.game) (gs : game_state) : game_state :=
  mkState g (gs_cursor gs) (gs_cursor_visible gs).

(** Boolean equality on positions. *)
Definition pos_eqb (p1 p2 : position) : bool :=
  Nat.eqb (prow p1) (prow p2) && Nat.eqb (pcol p1) (pcol p2).

(** Extract a board cell from the game-trees representation. *)
Definition get_cell (g : GT.game) (row col : nat) : GT.cell :=
  GT.get_cell (GT.board_of g) (GT.pos_of row col).

(** Count total pieces on the board. *)
Definition total_pieces (g : GT.game) : nat :=
  GT.count_pieces (GT.board_of g) GT.black +
  GT.count_pieces (GT.board_of g) GT.white.

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
Definition user_turn (g : GT.game) : bool :=
  GT.player_is_black (GT.turn_of g).

(** Whether the game is still in progress. *)
Definition game_ongoing (g : GT.game) : bool :=
  match GT.get_result g with
  | GT.ongoing => true
  | _ => false
  end.

(** Resolve AI turns and forced player passes until control returns to the user
    or the game ends. The fuel is generous because Reversi can force two
    consecutive passes near the end of the game. *)
Fixpoint resolve_automatic_turns (fuel : nat) (g : GT.game) : GT.game :=
  match fuel with
  | 0 => g
  | S fuel' =>
    match GT.get_result g with
    | GT.ongoing =>
      if user_turn g then
        match GT.valid_positions (GT.board_of g) GT.black with
        | [] => resolve_automatic_turns fuel' (GT.apply_move g GT.pass)
        | _ => g
        end
      else
        let ai := GT.ai_move g in
        match ai with
        | Some g' => resolve_automatic_turns fuel' g'
        | None => g
        end
    | _ => g
    end
  end.

(** Apply a user move from a concrete board coordinate, then resolve the AI
    reply and any forced passes. *)
Definition apply_user_move_at (p : position) (gs : game_state) : game_state :=
  let g := gs_core gs in
  match GT.get_result g with
  | GT.ongoing =>
    if user_turn g then
      if GT.is_valid_move (GT.board_of g) GT.black (prow p) (pcol p)
      then
        let g' := GT.apply_move g (GT.place (prow p) (pcol p)) in
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

(** Draw a filled disk row using local bounding-box offsets for the distance
    check and screen coordinates for the point placement. *)
Fixpoint filled_circle_row (ren : sdl_renderer) (cx y radius dy dx count : nat)
  : itree sdlE void :=
  match count with
  | 0 => Ret ghost
  | S count' =>
    let dy0 := abs_diff dy radius in
    let dx0 := abs_diff dx radius in
    let dist_sq := dx0 * dx0 + dy0 * dy0 in
    (if Nat.leb dist_sq (radius * radius)
     then sdl_draw_point ren (cx - radius + dx) y
     else Ret ghost) ;;
    filled_circle_row ren cx y radius dy (S dx) count'
  end.

(** Draw a filled circle centered at [(cx, cy)]. *)
Fixpoint filled_circle_rows (ren : sdl_renderer) (cx cy radius dy count : nat)
  : itree sdlE void :=
  match count with
  | 0 => Ret ghost
  | S count' =>
    let y := cy - radius + dy in
    filled_circle_row ren cx y radius dy 0 (radius + radius + 1) ;;
    filled_circle_rows ren cx cy radius (S dy) count'
  end.

Definition draw_filled_circle (ren : sdl_renderer) (cx cy radius : nat)
  : itree sdlE void :=
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
  : itree sdlE void :=
  match count with
  | 0 => Ret ghost
  | S count' =>
    (if Nat.testbit row_bits (4 - dx)
     then sdl_fill_rect ren (sx + dx * scale) sy scale scale
     else Ret ghost) ;;
    draw_glyph_row ren sx sy row_bits (S dx) count' scale
  end.

Fixpoint draw_glyph_rows (ren : sdl_renderer) (sx sy g row count scale : nat)
  : itree sdlE void :=
  match count with
  | 0 => Ret ghost
  | S count' =>
    draw_glyph_row ren sx (sy + row * scale) (glyph_row_data g row) 0 5 scale ;;
    draw_glyph_rows ren sx sy g (S row) count' scale
  end.

Definition draw_one_glyph (ren : sdl_renderer) (sx sy g scale : nat)
  : itree sdlE void :=
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
  : itree sdlE void :=
  match glyphs with
  | [] => Ret ghost
  | g :: rest =>
    draw_one_glyph ren sx sy g scale ;;
    draw_glyphs ren (sx + 6 * scale) sy scale rest
  end.

Fixpoint draw_number_digits (ren : sdl_renderer) (sx sy scale : nat)
    (digits : list nat) : itree sdlE void :=
  match digits with
  | [] => Ret ghost
  | d :: rest =>
    draw_one_glyph ren sx sy d scale ;;
    draw_number_digits ren (sx + 6 * scale) sy scale rest
  end.

Definition draw_number (ren : sdl_renderer) (n sx sy scale : nat) : itree sdlE void :=
  draw_number_digits ren sx sy scale (nat_digit_list n).

Definition draw_text (ren : sdl_renderer) (sx sy scale : nat) (msg : String.string)
  : itree sdlE void :=
  draw_glyphs ren sx sy scale (string_to_glyphs msg).

(** Render one board cell background. *)
Definition draw_board_cell (ren : sdl_renderer) (row col : nat) : itree sdlE void :=
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
  sdl_fill_rect ren x y 1 cell_size.

(** Render a legal-move hint dot. *)
Definition draw_hint (ren : sdl_renderer) (row col : nat) : itree sdlE void :=
  sdl_set_draw_color ren 232 198 77 ;;
  draw_filled_circle ren (cell_center_x col) (cell_center_y row) hint_radius.

(** Render a black or white disk with a light highlight. *)
Definition draw_disk (ren : sdl_renderer) (row col : nat) (is_black : bool)
  : itree sdlE void :=
  let cx := cell_center_x col in
  let cy := cell_center_y row in
  let outer := disk_radius in
  let inner := disk_radius - 4 in
  (if is_black
   then sdl_set_draw_color ren 124 132 138
   else sdl_set_draw_color ren 68 76 82) ;;
  draw_filled_circle ren cx cy outer ;;
  (if is_black
   then sdl_set_draw_color ren 22 24 27
   else sdl_set_draw_color ren 239 239 232) ;;
  draw_filled_circle ren cx cy inner ;;
  (if is_black
   then sdl_set_draw_color ren 92 101 108
   else sdl_set_draw_color ren 255 255 255) ;;
  draw_filled_circle ren (cx - 10) (cy - 10) 6.

(** Render the cursor frame if active. *)
Definition draw_cursor (ren : sdl_renderer) (p : position) (valid_move : option bool)
  : itree sdlE void :=
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
  sdl_fill_rect ren (x + cell_size - 3) y 3 cell_size.

(** Draw one row of the board. *)
Fixpoint draw_row (ren : sdl_renderer) (g : GT.game) (row col : nat)
    (cells : list GT.cell) : itree sdlE void :=
  match cells with
  | [] => Ret ghost
  | c :: rest =>
    draw_board_cell ren row col ;;
    (if GT.cell_is_empty c then
       if user_turn g && GT.is_valid_move (GT.board_of g) GT.black row col
       then draw_hint ren row col
     else Ret ghost
     else draw_disk ren row col (GT.player_is_black (GT.cell_player c))) ;;
    draw_row ren g row (S col) rest
  end.

(** Draw all board rows. *)
Fixpoint draw_rows (ren : sdl_renderer) (g : GT.game) (row : nat)
    (rows : list (list GT.cell)) : itree sdlE void :=
  match rows with
  | [] => Ret ghost
  | cells :: rest =>
    draw_row ren g row 0 cells ;;
    draw_rows ren g (S row) rest
  end.

(** Convert the flat 64-cell board into 8 rows for drawing. *)
Definition board_rows (g : GT.game) : list (list GT.cell) :=
  map (fun r => map (fun c => get_cell g r c) (seq 0 board_size)) (seq 0 board_size).

(** Short status message summarizing the game state. *)
Definition status_message (g : GT.game) : String.string :=
  match GT.result_code g with
  | 0 => if user_turn g then "Your turn"%string else "Computer thinking"%string
  | 1 => "You win"%string
  | 2 => "Computer wins"%string
  | _ => "Draw"%string
  end.

(** Helper label renderer. *)
Definition draw_label_number (ren : sdl_renderer) (label : String.string) (n x y : nat)
  : itree sdlE void :=
  sdl_set_draw_color ren 31 43 52 ;;
  draw_text ren x y 2 label ;;
  draw_number ren n (x + 84) y 2.

(** Draw the bottom status area. *)
Definition draw_status_bar (ren : sdl_renderer) (gs : game_state) : itree sdlE void :=
  let top := board_pixel_size in
  let g := gs_core gs in
  sdl_set_draw_color ren 227 219 198 ;;
  sdl_fill_rect ren 0 top win_width status_height ;;
  draw_label_number ren "Black"%string
    (GT.count_pieces (GT.board_of g) GT.black) 18 (top + 12) ;;
  draw_label_number ren "White"%string
    (GT.count_pieces (GT.board_of g) GT.white) 226 (top + 12) ;;
  sdl_set_draw_color ren 31 43 52 ;;
  draw_text ren 18 (top + 44) 2 (status_message g) ;;
  draw_text ren 18 (top + 74) 2 "Click to place    R restart    Esc quit"%string ;;
  if user_turn g
  then draw_text ren 18 (top + 100) 2 "You are black"%string
  else draw_text ren 18 (top + 100) 2 "Computer is white"%string.

(** Render a full frame. *)
Definition render_frame (ren : sdl_renderer) (gs : game_state) : itree sdlE void :=
  let g := gs_core gs in
  let cursor_validity :=
    if user_turn g
    then Some (GT.is_valid_move (GT.board_of g) GT.black
                  (prow (gs_cursor gs)) (pcol (gs_cursor gs)))
    else None in
  sdl_set_draw_color ren 92 60 36 ;;
  sdl_clear ren ;;
  draw_rows ren g 0 (board_rows g) ;;
  (if gs_cursor_visible gs
   then draw_cursor ren (gs_cursor gs) cursor_validity
   else Ret ghost) ;;
  draw_status_bar ren gs ;;
  sdl_present ren.

(** Loop state. *)
Record loop_state : Type := mkLoop {
  ls_game : game_state
}.

(** Sleep to maintain the target frame time. *)
Definition frame_delay (frame_start : nat) : itree sdlE void :=
  now2 <- sdl_get_ticks ;;
  let elapsed := now2 - frame_start in
  if Nat.ltb elapsed frame_ms
  then sdl_delay (frame_ms - elapsed)
  else Ret ghost.

(** Play the placement sound if new pieces appeared this frame. *)
Definition maybe_play_sound (before after : game_state) : itree sdlE void :=
  if Nat.ltb (total_pieces (gs_core before)) (total_pieces (gs_core after))
  then sdl_play_sound snd_tap
  else Ret ghost.

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
  let next_gs := set_core (resolve_automatic_turns 6 (gs_core render_gs)) render_gs in
  frame_delay frame_start ;;
  Ret (quit, mkLoop next_gs).

(** Initialize SDL. *)
Definition init_game : itree sdlE (sdl_window * sdl_renderer * loop_state) :=
  win <- sdl_create_window "Reversirocq" win_width win_height ;;
  ren <- sdl_create_renderer win ;;
  let gs := initial_state in
  render_frame ren gs ;;
  Ret (win, ren, mkLoop gs).

(** Release SDL resources. *)
Definition cleanup (ren : sdl_renderer) (win : sdl_window) : itree sdlE void :=
  sdl_destroy ren win.

End Reversirocq.

Import Reversirocq.
Import ITreeNotations.

Axiom c_int : Type.
Axiom c_zero : c_int.

(** Cleanup wrapper returning a C integer exit code. *)
Definition exit_game (win : sdl_window) (ren : sdl_renderer) : itree sdlE c_int :=
  cleanup ren win ;;
  Ret c_zero.

(** Main recursive SDL game loop with extraction-friendly fuel. *)
Fixpoint run_game (fuel : nat) (win : sdl_window) (ren : sdl_renderer)
                  (ls : loop_state) : itree sdlE c_int :=
  match fuel with
  | 0 => exit_game win ren
  | S fuel' =>
    res <- process_frame ren ls ;;
    let '(quit, ls') := res in
    if quit then exit_game win ren else run_game fuel' win ren ls'
  end.

(** Program entry point used by extraction. *)
Definition main : itree sdlE c_int :=
  init <- init_game ;;
  let '(win_ren, ls) := init in
  let '(win, ren) := win_ren in
  run_game 1000000 win ren ls.

Crane Extract Inlined Constant c_int => "int".
Crane Extract Inlined Constant c_zero => "0".

Crane Extraction "reversirocq" main.
