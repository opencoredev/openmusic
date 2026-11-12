import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Commands expire 2 minutes after they were sent.
crons.interval("sweep expired commands", { minutes: 1 }, internal.commands.sweep, {});
// Finished rate-limit counters and remembered settings writes. Both continue right away while a batch comes back full.
crons.interval("sweep expired throttles", { minutes: 1 }, internal.throttle.sweep, {});
crons.interval("sweep expired settings writes", { minutes: 5 }, internal.settings.sweepOps, {});
// Withdrawn registrations are refused for 30 days, then forgotten.
crons.interval("sweep cancelled registrations", { hours: 1 }, internal.account.sweepCancellations, {});
// Accounts nobody used for 60 days go, with all their rows.
crons.interval("sweep expired libraries", { hours: 1 }, internal.libraries.sweepExpired, {});
// What pairing by invite code left behind (owner-less libraries, invites, old counters).
crons.interval("sweep legacy pairing data", { minutes: 10 }, internal.legacy.sweep, {});

export default crons;
