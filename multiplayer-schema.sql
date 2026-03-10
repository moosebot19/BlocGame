-- =============================================
-- BLOC MULTIPLAYER — Database Schema
-- Run this in Supabase SQL Editor AFTER the original schema
-- =============================================

-- 1. PLAYER RANKINGS (extends players table)
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS elo integer DEFAULT 1000;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS rank_tier text DEFAULT 'bronze';
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS wins integer DEFAULT 0;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS losses integer DEFAULT 0;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS win_streak integer DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_players_elo ON public.players(elo DESC);

-- 2. MATCHMAKING QUEUE
CREATE TABLE IF NOT EXISTS public.match_queue (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  elo integer DEFAULT 1000,
  status text DEFAULT 'waiting', -- 'waiting', 'matched', 'expired'
  matched_with uuid REFERENCES public.players(id),
  match_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(player_id, status)
);

CREATE INDEX IF NOT EXISTS idx_queue_status ON public.match_queue(status, elo);
CREATE INDEX IF NOT EXISTS idx_queue_player ON public.match_queue(player_id);

-- 3. MATCHES TABLE
CREATE TABLE IF NOT EXISTS public.matches (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  player1_id uuid NOT NULL REFERENCES public.players(id),
  player2_id uuid REFERENCES public.players(id), -- null = bot match
  piece_seed integer NOT NULL, -- shared RNG seed so both get same pieces
  status text DEFAULT 'active', -- 'active', 'finished', 'abandoned'
  winner_id uuid REFERENCES public.players(id),
  player1_score integer DEFAULT 0,
  player2_score integer DEFAULT 0,
  player1_lines integer DEFAULT 0,
  player2_lines integer DEFAULT 0,
  is_bot_match boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  finished_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_matches_status ON public.matches(status);
CREATE INDEX IF NOT EXISTS idx_matches_players ON public.matches(player1_id, player2_id);

-- 4. MATCH EVENTS (real-time game state sync)
CREATE TABLE IF NOT EXISTS public.match_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  player_id uuid NOT NULL REFERENCES public.players(id),
  event_type text NOT NULL, -- 'place', 'clear', 'junk_sent', 'junk_received', 'power_used', 'game_over'
  data jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_match ON public.match_events(match_id, created_at);

-- 5. RLS POLICIES
ALTER TABLE public.match_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view queue" ON public.match_queue FOR SELECT USING (true);
CREATE POLICY "Anyone can join queue" ON public.match_queue FOR INSERT WITH CHECK (true);
CREATE POLICY "Anyone can update queue" ON public.match_queue FOR UPDATE USING (true);
CREATE POLICY "Anyone can leave queue" ON public.match_queue FOR DELETE USING (true);

CREATE POLICY "Anyone can view matches" ON public.matches FOR SELECT USING (true);
CREATE POLICY "Anyone can create matches" ON public.matches FOR INSERT WITH CHECK (true);
CREATE POLICY "Anyone can update matches" ON public.matches FOR UPDATE USING (true);

CREATE POLICY "Anyone can view events" ON public.match_events FOR SELECT USING (true);
CREATE POLICY "Anyone can create events" ON public.match_events FOR INSERT WITH CHECK (true);

-- 6. MATCHMAKING FUNCTION
CREATE OR REPLACE FUNCTION public.join_matchmaking(p_player_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_player public.players;
  v_opponent public.match_queue;
  v_match_id uuid;
  v_seed integer;
BEGIN
  -- Get player info
  SELECT * INTO v_player FROM public.players WHERE id = p_player_id;
  IF v_player.id IS NULL THEN
    RETURN json_build_object('error', 'Player not found');
  END IF;

  -- Remove any stale queue entries for this player
  DELETE FROM public.match_queue WHERE player_id = p_player_id;

  -- Look for an opponent within ELO range (±300, expanding)
  SELECT * INTO v_opponent
  FROM public.match_queue
  WHERE status = 'waiting'
    AND player_id != p_player_id
    AND ABS(elo - v_player.elo) <= 500
  ORDER BY ABS(elo - v_player.elo), created_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF v_opponent.id IS NOT NULL THEN
    -- Found opponent — create match
    v_seed := floor(random() * 2147483647)::integer;
    
    INSERT INTO public.matches (player1_id, player2_id, piece_seed, status)
    VALUES (v_opponent.player_id, p_player_id, v_seed, 'active')
    RETURNING id INTO v_match_id;

    -- Update queue entry
    UPDATE public.match_queue
    SET status = 'matched', matched_with = p_player_id, match_id = v_match_id
    WHERE id = v_opponent.id;

    RETURN json_build_object(
      'status', 'matched',
      'match_id', v_match_id,
      'opponent_id', v_opponent.player_id,
      'opponent_nickname', (SELECT nickname FROM public.players WHERE id = v_opponent.player_id),
      'opponent_elo', v_opponent.elo,
      'piece_seed', v_seed,
      'player_number', 2
    );
  ELSE
    -- No opponent found — add to queue
    INSERT INTO public.match_queue (player_id, elo, status)
    VALUES (p_player_id, v_player.elo, 'waiting');

    RETURN json_build_object('status', 'waiting');
  END IF;
END;
$$;

-- 7. CHECK QUEUE STATUS (called by waiting player to see if matched)
CREATE OR REPLACE FUNCTION public.check_matchmaking(p_player_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_entry public.match_queue;
  v_match public.matches;
BEGIN
  SELECT * INTO v_entry
  FROM public.match_queue
  WHERE player_id = p_player_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_entry.id IS NULL THEN
    RETURN json_build_object('status', 'not_in_queue');
  END IF;

  IF v_entry.status = 'matched' AND v_entry.match_id IS NOT NULL THEN
    SELECT * INTO v_match FROM public.matches WHERE id = v_entry.match_id;
    
    RETURN json_build_object(
      'status', 'matched',
      'match_id', v_match.id,
      'opponent_id', v_entry.matched_with,
      'opponent_nickname', (SELECT nickname FROM public.players WHERE id = v_entry.matched_with),
      'opponent_elo', (SELECT elo FROM public.players WHERE id = v_entry.matched_with),
      'piece_seed', v_match.piece_seed,
      'player_number', 1
    );
  END IF;

  RETURN json_build_object('status', 'waiting');
END;
$$;

-- 8. CANCEL MATCHMAKING
CREATE OR REPLACE FUNCTION public.cancel_matchmaking(p_player_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM public.match_queue WHERE player_id = p_player_id AND status = 'waiting';
  RETURN json_build_object('status', 'cancelled');
END;
$$;

-- 9. FINISH MATCH + ELO UPDATE
CREATE OR REPLACE FUNCTION public.finish_match(
  p_match_id uuid,
  p_winner_id uuid,
  p_player1_score integer DEFAULT 0,
  p_player2_score integer DEFAULT 0,
  p_player1_lines integer DEFAULT 0,
  p_player2_lines integer DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_match public.matches;
  v_loser_id uuid;
  v_winner_elo integer;
  v_loser_elo integer;
  v_k integer := 32;
  v_expected float;
  v_elo_change integer;
  v_winner_new_elo integer;
  v_loser_new_elo integer;
  v_winner_tier text;
  v_loser_tier text;
BEGIN
  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF v_match.id IS NULL OR v_match.status = 'finished' THEN
    RETURN json_build_object('error', 'Match not found or already finished');
  END IF;

  -- Update match record
  UPDATE public.matches SET
    status = 'finished',
    winner_id = p_winner_id,
    player1_score = p_player1_score,
    player2_score = p_player2_score,
    player1_lines = p_player1_lines,
    player2_lines = p_player2_lines,
    finished_at = now()
  WHERE id = p_match_id;

  -- Skip ELO for bot matches
  IF v_match.is_bot_match THEN
    RETURN json_build_object('status', 'finished', 'elo_change', 0);
  END IF;

  -- Calculate ELO
  v_loser_id := CASE WHEN p_winner_id = v_match.player1_id THEN v_match.player2_id ELSE v_match.player1_id END;
  
  IF v_loser_id IS NULL THEN
    RETURN json_build_object('status', 'finished', 'elo_change', 0);
  END IF;

  SELECT elo INTO v_winner_elo FROM public.players WHERE id = p_winner_id;
  SELECT elo INTO v_loser_elo FROM public.players WHERE id = v_loser_id;

  v_expected := 1.0 / (1.0 + power(10.0, (v_loser_elo - v_winner_elo)::float / 400.0));
  v_elo_change := greatest(1, round(v_k * (1.0 - v_expected))::integer);

  v_winner_new_elo := v_winner_elo + v_elo_change;
  v_loser_new_elo := greatest(100, v_loser_elo - v_elo_change);

  -- Determine rank tiers
  v_winner_tier := CASE
    WHEN v_winner_new_elo >= 2000 THEN 'master'
    WHEN v_winner_new_elo >= 1600 THEN 'diamond'
    WHEN v_winner_new_elo >= 1400 THEN 'platinum'
    WHEN v_winner_new_elo >= 1200 THEN 'gold'
    WHEN v_winner_new_elo >= 1000 THEN 'silver'
    ELSE 'bronze'
  END;

  v_loser_tier := CASE
    WHEN v_loser_new_elo >= 2000 THEN 'master'
    WHEN v_loser_new_elo >= 1600 THEN 'diamond'
    WHEN v_loser_new_elo >= 1400 THEN 'platinum'
    WHEN v_loser_new_elo >= 1200 THEN 'gold'
    WHEN v_loser_new_elo >= 1000 THEN 'silver'
    ELSE 'bronze'
  END;

  -- Update players
  UPDATE public.players SET
    elo = v_winner_new_elo,
    rank_tier = v_winner_tier,
    wins = wins + 1,
    win_streak = win_streak + 1
  WHERE id = p_winner_id;

  UPDATE public.players SET
    elo = v_loser_new_elo,
    rank_tier = v_loser_tier,
    losses = losses + 1,
    win_streak = 0
  WHERE id = v_loser_id;

  -- Clean up queue
  DELETE FROM public.match_queue WHERE match_id = p_match_id;

  RETURN json_build_object(
    'status', 'finished',
    'elo_change', v_elo_change,
    'winner_new_elo', v_winner_new_elo,
    'loser_new_elo', v_loser_new_elo,
    'winner_tier', v_winner_tier,
    'loser_tier', v_loser_tier
  );
END;
$$;

-- 10. GET PLAYER RANK INFO
CREATE OR REPLACE FUNCTION public.get_player_rank(p_player_id uuid)
RETURNS json
LANGUAGE sql SECURITY DEFINER
AS $$
  SELECT json_build_object(
    'elo', p.elo,
    'rank_tier', p.rank_tier,
    'wins', p.wins,
    'losses', p.losses,
    'win_streak', p.win_streak,
    'global_rank', (SELECT count(*) + 1 FROM public.players WHERE elo > p.elo)
  )
  FROM public.players p
  WHERE p.id = p_player_id;
$$;

-- 11. ENABLE REALTIME on match_events for live game sync
ALTER PUBLICATION supabase_realtime ADD TABLE public.match_events;
