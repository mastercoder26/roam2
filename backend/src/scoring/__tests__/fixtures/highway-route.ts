import type { ParsedRoute } from "../../../types.js";

/** Simulates a long I-95 style highway corridor. */
export const highwayRoute: ParsedRoute = {
  distanceMeters: 160_934, // ~100 miles
  durationSeconds: 5400,
  staticDurationSeconds: 5100,
  polyline: "encoded_highway_polyline",
  bounds: {
    southwest: { lat: 25.7, lng: -80.3 },
    northeast: { lat: 28.5, lng: -80.1 },
  },
  routeLabels: ["DEFAULT_ROUTE"],
  steps: [
    {
      distanceMeters: 80_000,
      staticDurationSeconds: 2400,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 50_000,
      staticDurationSeconds: 1500,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95 toward Jacksonville",
    },
    {
      distanceMeters: 25_000,
      staticDurationSeconds: 900,
      maneuver: "MERGE",
      navigationInstruction: "Merge onto US 1 Expressway",
    },
    {
      distanceMeters: 5934,
      staticDurationSeconds: 300,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Take exit 12 toward Downtown",
    },
  ],
};
