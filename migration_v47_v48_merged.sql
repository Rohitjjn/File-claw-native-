-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  Migration v47+v48 MERGED — Admin Audit Log + Notification Fix      ║
-- ║  Run this in Supabase SQL Editor.                                   ║
-- ║                                                                      ║
-- ║  Combines:                                                           ║
-- ║  • v47: Admin audit log table + RPC + audit logging in admin RPCs   ║
-- ║  • v48: Fix notification duplication (3x bug)                       ║
-- ║                                                                      ║
-- ║  IMPORTANT: All functions that may have changed return types        ║
-- ║  include DROP FUNCTION IF EXISTS before CREATE to avoid error:      ║
-- ║  "cannot change return type of existing function"                   ║
-- ╚══════════════════════════════════════════════════════════════════════╝

-- ── 1. Create audit log table ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  admin_email TEXT NOT NULL DEFAULT '',
  action_type TEXT NOT NULL,
  target_user_id UUID,
  target_user_email TEXT DEFAULT '',
  target_user_name TEXT DEFAULT '',
  details TEXT DEFAULT '',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index for fast queries
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON public.admin_audit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_action_type ON public.admin_audit_log (action_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_target_user ON public.admin_audit_log (target_user_id);

-- Enable RLS
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

-- Only admins can read audit logs
DROP POLICY IF EXISTS "Admins can read audit logs" ON public.admin_audit_log;
CREATE POLICY "Admins can read audit logs"
  ON public.admin_audit_log FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
      AND (profiles.is_admin = true OR profiles.email = 'userrohitai011@gmail.com')
    )
  );

-- Service role can insert (for RPCs that run as SECURITY DEFINER)
DROP POLICY IF EXISTS "Service role can insert audit logs" ON public.admin_audit_log;
CREATE POLICY "Service role can insert audit logs"
  ON public.admin_audit_log FOR INSERT
  WITH CHECK (true);

-- ── 2. Helper function to log admin actions ─────────────────────────────
DROP FUNCTION IF EXISTS public.log_admin_action(TEXT, TEXT, UUID, TEXT, TEXT, TEXT, JSONB);
CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_admin_email TEXT,
  p_action_type TEXT,
  p_target_user_id UUID DEFAULT NULL,
  p_target_user_email TEXT DEFAULT '',
  p_target_user_name TEXT DEFAULT '',
  p_details TEXT DEFAULT '',
  p_metadata JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.admin_audit_log (
    admin_email, action_type, target_user_id, target_user_email,
    target_user_name, details, metadata
  ) VALUES (
    p_admin_email, p_action_type, p_target_user_id, p_target_user_email,
    p_target_user_name, p_details, p_metadata
  );
END;
$$;

-- ── 3. RPC to fetch audit logs for admin panel ──────────────────────────
DROP FUNCTION IF EXISTS public.admin_get_audit_logs();
CREATE OR REPLACE FUNCTION public.admin_get_audit_logs()
RETURNS TABLE(
  id UUID,
  admin_email TEXT,
  action_type TEXT,
  target_user_email TEXT,
  target_user_name TEXT,
  details TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Verify caller is admin
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND (profiles.is_admin = true OR profiles.email = 'userrohitai011@gmail.com')
  ) THEN
    RAISE EXCEPTION 'Access denied: admin privileges required';
  END IF;

  RETURN QUERY
    SELECT
      al.id,
      al.admin_email,
      al.action_type,
      al.target_user_email,
      al.target_user_name,
      al.details,
      al.created_at
    FROM public.admin_audit_log al
    ORDER BY al.created_at DESC
    LIMIT 500;
END;
$$;

-- ── 4. Admin RPCs with audit logging ────────────────────────────────────
-- All functions include DROP FUNCTION IF EXISTS to handle signature changes.

-- 4a: admin_grant_plan
DROP FUNCTION IF EXISTS public.admin_grant_plan(UUID, TEXT, INTEGER, NUMERIC, BOOLEAN);
CREATE OR REPLACE FUNCTION public.admin_grant_plan(
  target_user_id UUID,
  plan_name_val TEXT,
  days_val INTEGER,
  price_paid NUMERIC DEFAULT 0,
  is_extension BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_email TEXT;
  v_user_name TEXT;
  v_admin_email TEXT;
  v_existing_plan_end TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
  v_action_type TEXT;
BEGIN
  -- Get admin email
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;

  -- Get target user info
  SELECT email, name INTO v_user_email, v_user_name FROM public.profiles WHERE id = target_user_id LIMIT 1;

  -- Get current plan end date for extension logic
  SELECT plan_end_date INTO v_existing_plan_end FROM public.profiles WHERE id = target_user_id LIMIT 1;

  -- Calculate new end date
  IF is_extension AND v_existing_plan_end IS NOT NULL AND v_existing_plan_end > now() THEN
    v_new_end := v_existing_plan_end + make_interval(days => days_val);
    v_action_type := 'PLAN_EXTENSION';
  ELSE
    v_new_end := now() + make_interval(days => days_val);
    v_action_type := 'PLAN_GRANT';
  END IF;

  -- Update user profile
  UPDATE public.profiles SET
    plan_active = true,
    plan_name = plan_name_val,
    plan_end_date = v_new_end,
    plan_change_log = COALESCE(plan_change_log, '') || E'\n' ||
      CASE
        WHEN v_action_type = 'PLAN_EXTENSION' THEN 'EXTENDED BY ' || days_val || ' DAYS (' || plan_name_val || ', Rs.' || price_paid || ') at ' || now()::text
        ELSE 'GRANTED ' || plan_name_val || ' (' || days_val || ' days, Rs.' || price_paid || ') at ' || now()::text
      END
  WHERE id = target_user_id;

  -- Create notification for the user
  INSERT INTO public.notifications (user_id, title, message, notification_type, target_group)
  VALUES (
    target_user_id,
    CASE WHEN v_action_type = 'PLAN_EXTENSION' THEN 'Plan Extended!' ELSE 'Plan Activated!' END,
    'Plan Type: ' || plan_name_val || E'\nAmount Paid: Rs.' || price_paid || E'\nStatus: Active',
    CASE WHEN v_action_type = 'PLAN_EXTENSION' THEN 'extension' ELSE 'individual_plan' END,
    NULL
  );

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => v_action_type,
    p_target_user_id => target_user_id,
    p_target_user_email => COALESCE(v_user_email, ''),
    p_target_user_name => COALESCE(v_user_name, ''),
    p_details => CASE
      WHEN v_action_type = 'PLAN_EXTENSION' THEN 'Extended ' || plan_name_val || ' by ' || days_val || ' days (Rs.' || price_paid || ')'
      ELSE 'Granted ' || plan_name_val || ' for ' || days_val || ' days (Rs.' || price_paid || ')'
    END,
    p_metadata => jsonb_build_object(
      'plan_name', plan_name_val,
      'days', days_val,
      'price_paid', price_paid,
      'is_extension', is_extension
    )
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4b: admin_revoke_plan
DROP FUNCTION IF EXISTS public.admin_revoke_plan(UUID);
CREATE OR REPLACE FUNCTION public.admin_revoke_plan(
  target_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_email TEXT;
  v_user_name TEXT;
  v_admin_email TEXT;
  v_plan_name TEXT;
BEGIN
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;
  SELECT email, name, plan_name INTO v_user_email, v_user_name, v_plan_name FROM public.profiles WHERE id = target_user_id LIMIT 1;

  UPDATE public.profiles SET
    plan_active = false,
    plan_name = NULL,
    plan_end_date = NULL
  WHERE id = target_user_id;

  INSERT INTO public.notifications (user_id, title, message, notification_type, target_group)
  VALUES (target_user_id, 'Plan Deactivated', 'Your plan has been deactivated by the admin.', 'plan_revoke', NULL);

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => 'PLAN_REVOKE',
    p_target_user_id => target_user_id,
    p_target_user_email => COALESCE(v_user_email, ''),
    p_target_user_name => COALESCE(v_user_name, ''),
    p_details => 'Revoked plan: ' || COALESCE(v_plan_name, 'Unknown'),
    p_metadata => jsonb_build_object('plan_name', v_plan_name)
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4c: admin_block_user
DROP FUNCTION IF EXISTS public.admin_block_user(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.admin_block_user(
  p_user_id UUID,
  p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_email TEXT;
  v_user_name TEXT;
  v_admin_email TEXT;
BEGIN
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;
  SELECT email, name INTO v_user_email, v_user_name FROM public.profiles WHERE id = p_user_id LIMIT 1;

  UPDATE public.profiles SET
    is_blocked_by_admin = true,
    blocked_reason = p_reason
  WHERE id = p_user_id;

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => 'BLOCK_USER',
    p_target_user_id => p_user_id,
    p_target_user_email => COALESCE(v_user_email, ''),
    p_target_user_name => COALESCE(v_user_name, ''),
    p_details => 'Blocked user. Reason: ' || COALESCE(p_reason, 'No reason specified'),
    p_metadata => jsonb_build_object('reason', p_reason)
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4d: admin_unblock_user
DROP FUNCTION IF EXISTS public.admin_unblock_user(UUID);
CREATE OR REPLACE FUNCTION public.admin_unblock_user(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_email TEXT;
  v_user_name TEXT;
  v_admin_email TEXT;
BEGIN
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;
  SELECT email, name INTO v_user_email, v_user_name FROM public.profiles WHERE id = p_user_id LIMIT 1;

  UPDATE public.profiles SET
    is_blocked_by_admin = false,
    blocked_reason = NULL
  WHERE id = p_user_id;

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => 'UNBLOCK_USER',
    p_target_user_id => p_user_id,
    p_target_user_email => COALESCE(v_user_email, ''),
    p_target_user_name => COALESCE(v_user_name, ''),
    p_details => 'Unblocked user'
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 4e: admin_set_maintenance
DROP FUNCTION IF EXISTS public.admin_set_maintenance(BOOLEAN) CASCADE;
CREATE OR REPLACE FUNCTION public.admin_set_maintenance(
  p_enabled BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_email TEXT;
BEGIN
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;

  -- Upsert maintenance setting (support both site_settings and admin_settings tables)
  INSERT INTO public.site_settings (key, value)
  VALUES ('maintenance_mode', CASE WHEN p_enabled THEN '"true"' ELSE '"false"' END)
  ON CONFLICT (key) DO UPDATE SET value = CASE WHEN p_enabled THEN '"true"' ELSE '"false"' END;

  -- Also update admin_settings for backward compatibility
  INSERT INTO public.admin_settings (setting_key, setting_value, updated_at)
  VALUES ('maintenance_mode', p_enabled::text, now())
  ON CONFLICT (setting_key)
  DO UPDATE SET setting_value = EXCLUDED.setting_value, updated_at = now();

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => 'TOGGLE_MAINTENANCE',
    p_details => CASE WHEN p_enabled THEN 'Enabled maintenance mode' ELSE 'Disabled maintenance mode' END,
    p_metadata => jsonb_build_object('enabled', p_enabled)
  );

  RETURN jsonb_build_object('success', true, 'maintenance_enabled', p_enabled);
END;
$$;

-- ── 5. v48: Fix admin_send_notification (single row for broadcasts) ──────
-- Instead of inserting one row per user (which caused 3x duplication),
-- we now insert ONE row with user_id=NULL and target_group set.
-- get_user_notifications will return this row for matching users.
DROP FUNCTION IF EXISTS public.admin_send_notification(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.admin_send_notification(
  p_title TEXT,
  p_message TEXT,
  p_target_group TEXT DEFAULT 'all'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_email TEXT;
  v_count INTEGER := 0;
BEGIN
  SELECT email INTO v_admin_email FROM public.profiles WHERE id = auth.uid() LIMIT 1;

  -- Insert a SINGLE row with user_id=NULL for broadcasts.
  -- get_user_notifications will return it for matching users.
  -- This eliminates the duplication bug where per-user rows + target_group
  -- matching caused the same notification to appear 3 times.
  INSERT INTO public.notifications (user_id, title, message, notification_type, target_group)
  VALUES (NULL, p_title, p_message, 'admin_broadcast', p_target_group);

  -- Count matching users for the response
  IF p_target_group = 'all' THEN
    SELECT count(*) INTO v_count FROM public.profiles WHERE email != 'userrohitai011@gmail.com';
  ELSIF p_target_group = 'paid_users' THEN
    SELECT count(*) INTO v_count FROM public.profiles WHERE plan_active = true AND email != 'userrohitai011@gmail.com';
  ELSIF p_target_group = 'free_users' THEN
    SELECT count(*) INTO v_count FROM public.profiles WHERE (plan_active = false OR plan_active IS NULL) AND email != 'userrohitai011@gmail.com';
  ELSIF p_target_group = 'guest' THEN
    v_count := 0;
  END IF;

  -- Log the audit action
  PERFORM public.log_admin_action(
    p_admin_email => COALESCE(v_admin_email, ''),
    p_action_type => 'SEND_NOTIFICATION',
    p_details => 'Sent notification to ' || p_target_group || ': ' || LEFT(p_message, 100),
    p_metadata => jsonb_build_object(
      'title', p_title,
      'message', p_message,
      'target_group', p_target_group,
      'recipients', v_count
    )
  );

  RETURN jsonb_build_object('success', true, 'recipients', v_count);
END;
$$;

-- ── 6. v48: Fix get_user_notifications (properly handle broadcasts) ──────
-- Returns:
--   a) Notifications where user_id = p_user_id (personal notifications)
--   b) Broadcast notifications where user_id IS NULL AND target_group matches
-- Uses UNION to avoid duplicates, and excludes dismissed notifications.
DROP FUNCTION IF EXISTS public.get_user_notifications(UUID);
CREATE OR REPLACE FUNCTION public.get_user_notifications(
  p_user_id UUID
)
RETURNS TABLE(
  id UUID,
  title TEXT,
  message TEXT,
  hindi_title TEXT,
  hindi_message TEXT,
  henglish_title TEXT,
  henglish_message TEXT,
  is_read BOOLEAN,
  target_group TEXT,
  created_at TIMESTAMPTZ,
  font_guide BOOLEAN,
  notification_type TEXT,
  cta_text TEXT,
  cta_action TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_plan_active BOOLEAN;
  v_user_email TEXT;
BEGIN
  -- Get user info for target_group matching
  SELECT plan_active, email INTO v_user_plan_active, v_user_email
  FROM public.profiles WHERE id = p_user_id LIMIT 1;

  RETURN QUERY
    -- Personal notifications (user_id matches)
    SELECT
      n.id, n.title, n.message,
      n.hindi_title, n.hindi_message,
      n.henglish_title, n.henglish_message,
      n.is_read, n.target_group, n.created_at,
      n.font_guide, n.notification_type, n.cta_text, n.cta_action
    FROM public.notifications n
    WHERE n.user_id = p_user_id
      AND n.id NOT IN (
        SELECT nd.notification_id FROM public.notification_dismissals nd
        WHERE nd.user_id = p_user_id
      )

    UNION

    -- Broadcast notifications (user_id IS NULL, target_group matches)
    SELECT
      n.id, n.title, n.message,
      n.hindi_title, n.hindi_message,
      n.henglish_title, n.henglish_message,
      -- For broadcast notifications, check if this user has dismissed it
      CASE WHEN EXISTS (
        SELECT 1 FROM public.notification_dismissals nd
        WHERE nd.notification_id = n.id AND nd.user_id = p_user_id
      ) THEN true ELSE n.is_read END,
      n.target_group, n.created_at,
      n.font_guide, n.notification_type, n.cta_text, n.cta_action
    FROM public.notifications n
    WHERE n.user_id IS NULL
      AND n.target_group IS NOT NULL
      -- Match target_group to user type
      AND (
        n.target_group = 'all'
        OR (n.target_group = 'paid_users' AND v_user_plan_active = true)
        OR (n.target_group = 'free_users' AND (v_user_plan_active = false OR v_user_plan_active IS NULL))
        OR (n.target_group = 'guest')
      )
      AND n.id NOT IN (
        SELECT nd.notification_id FROM public.notification_dismissals nd
        WHERE nd.user_id = p_user_id
      )

    ORDER BY created_at DESC;
END;
$$;

-- ── 7. v48: Clean up old duplicate broadcast notifications ──────────────
-- Delete old per-user broadcast notifications (they were created by the
-- old admin_send_notification and caused the 3x duplication).
-- Keep only one per (title, message, target_group, created_at::date).
DELETE FROM public.notifications a
USING public.notifications b
WHERE a.user_id IS NOT NULL
  AND a.notification_type = 'admin_broadcast'
  AND a.target_group IS NOT NULL
  AND b.id != a.id
  AND b.title = a.title
  AND b.message = a.message
  AND b.target_group = a.target_group
  AND b.notification_type = 'admin_broadcast'
  AND b.created_at::date = a.created_at::date
  AND a.id < b.id;
