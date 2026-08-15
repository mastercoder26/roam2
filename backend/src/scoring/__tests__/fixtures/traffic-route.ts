import type { ParsedRoute } from "../../../types.js";
import { highwayRoute } from "./highway-route.js";

/** Same highway distance with heavy traffic delay. */
export const trafficHeavyRoute: ParsedRoute = {
  ...highwayRoute,
  durationSeconds: 6600,
  staticDurationSeconds: 5100,
};

/** Light traffic variant for comparison. */
export const trafficLightRoute: ParsedRoute = {
  ...highwayRoute,
  durationSeconds: 5200,
  staticDurationSeconds: 5100,
};
