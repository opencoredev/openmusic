// Who may call the sync functions: users of one Clerk application. Clerk issues the JWT (template "convex",
// audience "convex"); Convex checks it against the issuer's JWKS. Set CLERK_JWT_ISSUER_DOMAIN on the deployment
// (Clerk dashboard › API keys › Frontend API URL, e.g. https://clerk.example.com) before pushing these functions.
// See docs/self-hosting.md.
import type { AuthConfig } from "convex/server";

const domain = process.env.CLERK_JWT_ISSUER_DOMAIN;
if (domain === undefined || domain.length === 0) {
  throw new Error("Set CLERK_JWT_ISSUER_DOMAIN to your Clerk Frontend API URL (see docs/self-hosting.md).");
}

export default {
  providers: [{ domain, applicationID: "convex" }],
} satisfies AuthConfig;
