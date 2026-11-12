/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as account from "../account.js";
import type * as cleanup from "../cleanup.js";
import type * as commands from "../commands.js";
import type * as config from "../config.js";
import type * as crons from "../crons.js";
import type * as devices from "../devices.js";
import type * as keys from "../keys.js";
import type * as legacy from "../legacy.js";
import type * as lib from "../lib.js";
import type * as libraries from "../libraries.js";
import type * as model from "../model.js";
import type * as playback from "../playback.js";
import type * as settings from "../settings.js";
import type * as throttle from "../throttle.js";
import type * as vault from "../vault.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  account: typeof account;
  cleanup: typeof cleanup;
  commands: typeof commands;
  config: typeof config;
  crons: typeof crons;
  devices: typeof devices;
  keys: typeof keys;
  legacy: typeof legacy;
  lib: typeof lib;
  libraries: typeof libraries;
  model: typeof model;
  playback: typeof playback;
  settings: typeof settings;
  throttle: typeof throttle;
  vault: typeof vault;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
