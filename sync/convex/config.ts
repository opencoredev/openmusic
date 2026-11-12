import { v, type Infer } from "convex/values";
import { query } from "./_generated/server";

/** How clients sign in to this server. A self-hoster sets `CLERK_PUBLISHABLE_KEY` and gives OpenMusic one URL. */
export const authConfigV = v.union(
  v.object({ kind: v.literal("clerk"), publishableKey: v.string() }),
  /** The deployment has no (valid) `CLERK_PUBLISHABLE_KEY`; nobody can sign in yet. */
  v.object({ kind: v.literal("notConfigured") }),
);
export type ServerAuthConfig = Infer<typeof authConfigV>;

const publishableKeyPattern = /^pk_(test|live)_[A-Za-z0-9+/=]+$/;

export function readAuthConfig(publishableKey: string | undefined): ServerAuthConfig {
  if (publishableKey === undefined || !publishableKeyPattern.test(publishableKey)) return { kind: "notConfigured" };
  return { kind: "clerk", publishableKey };
}

/**
 * Public: what a client needs before it can sign in. Needs no identity. The publishable key is public by design
 * (it names the Clerk Frontend API host); nothing secret comes back.
 */
export const get = query({
  args: {},
  returns: v.object({ auth: authConfigV }),
  handler: async () => ({ auth: readAuthConfig(process.env.CLERK_PUBLISHABLE_KEY) }),
});
