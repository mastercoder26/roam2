import type { ParsedRoute } from "../../../types.js";

/** Clustered merge/weave section on an otherwise smooth highway */
export const mergeClusterRoute: ParsedRoute = {
  distanceMeters: 48_280, // ~30 miles
  durationSeconds: 2400,
  staticDurationSeconds: 2100,
  polyline: "encoded_merge_cluster_polyline",
  bounds: {
    southwest: { lat: 39.9, lng: -75.2 },
    northeast: { lat: 40.1, lng: -74.9 },
  },
  steps: [
    {
      distanceMeters: 20_000,
      staticDurationSeconds: 900,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 800,
      staticDurationSeconds: 45,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Take exit 32A",
    },
    {
      distanceMeters: 600,
      staticDurationSeconds: 40,
      maneuver: "MERGE",
      navigationInstruction: "Merge onto I-676 West",
    },
    {
      distanceMeters: 500,
      staticDurationSeconds: 35,
      maneuver: "RAMP_LEFT",
      navigationInstruction: "Keep left toward Central Philly",
    },
    {
      distanceMeters: 700,
      staticDurationSeconds: 50,
      maneuver: "MERGE",
      navigationInstruction: "Merge onto I-76 West",
    },
    {
      distanceMeters: 400,
      staticDurationSeconds: 30,
      maneuver: "RAMP_RIGHT",
      navigationInstruction: "Exit toward Walt Whitman Bridge",
    },
    {
      distanceMeters: 600,
      staticDurationSeconds: 40,
      maneuver: "MERGE",
      navigationInstruction: "Merge onto I-295 South",
    },
    {
      distanceMeters: 24_680,
      staticDurationSeconds: 960,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95 South",
    },
  ],
};

/** Smooth highway equivalent distance without merge cluster */
export const smoothHighwayEquivalent: ParsedRoute = {
  distanceMeters: 48_280,
  durationSeconds: 2100,
  staticDurationSeconds: 2000,
  polyline: "encoded_smooth_highway_polyline",
  bounds: {
    southwest: { lat: 39.9, lng: -75.2 },
    northeast: { lat: 40.1, lng: -74.9 },
  },
  steps: [
    {
      distanceMeters: 45_000,
      staticDurationSeconds: 1800,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 3_280,
      staticDurationSeconds: 200,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-95",
    },
  ],
};
