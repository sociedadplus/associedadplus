import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabasePublishableKey =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!supabaseUrl || !supabasePublishableKey) {
  throw new Error(
    "As variáveis de ambiente do Supabase não foram configuradas."
  );
}

export const supabase = createClient(
  supabaseUrl,
  supabasePublishableKey
);