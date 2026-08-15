import type { ParsedRoute } from "../../../types.js";
import { highwayRoute } from "./highway-route.js";

/** 2.5+ hour mostly-highway trip */
export const longDriveRoute: ParsedRoute = {
  ...highwayRoute,
  distanceMeters: 402_336, // ~250 miles
  durationSeconds: 10_800,
  staticDurationSeconds: 10_200,
  steps: [
    {
      distanceMeters: 200_000,
      staticDurationSeconds: 5100,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 150_000,
      staticDurationSeconds: 3800,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95 toward Richmond",
    },
    {
      distanceMeters: 40_000,
      staticDurationSeconds: 1000,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95",
    },
    {
      distanceMeters: 12_336,
      staticDurationSeconds: 300,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Take exit toward downtown",
    },
  ],
};
