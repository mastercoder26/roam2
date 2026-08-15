import type { ParsedRoute } from "../../../types.js";

/** Urban block with 5 turns within ~500 m — tight turn cluster. */
export const turnClusterRoute: ParsedRoute = {
  distanceMeters: 8_000,
  durationSeconds: 1200,
  staticDurationSeconds: 1100,
  polyline: "encoded_turn_cluster_polyline",
  bounds: {
    southwest: { lat: 40.71, lng: -74.01 },
    northeast: { lat: 40.72, lng: -73.99 },
  },
  steps: [
    {
      distanceMeters: 500,
      staticDurationSeconds: 90,
      maneuver: "DEPART",
      navigationInstruction: "Head east on Main St",
    },
    {
      distanceMeters: 100,
      staticDurationSeconds: 45,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto 1st Ave",
    },
    {
      distanceMeters: 80,
      staticDurationSeconds: 40,
      maneuver: "TURN_RIGHT",
      navigationInstruction: "Turn right onto Oak St",
    },
    {
      distanceMeters: 120,
      staticDurationSeconds: 50,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto Pine St",
    },
    {
      distanceMeters: 90,
      staticDurationSeconds: 45,
      maneuver: "TURN_SHARP_RIGHT",
      navigationInstruction: "Sharp right onto Elm St",
    },
    {
      distanceMeters: 110,
      staticDurationSeconds: 50,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto Cedar Ave",
    },
    {
      distanceMeters: 7_100,
      staticDurationSeconds: 780,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on Cedar Ave",
    },
  ],
};

/** Same turn count spread over ~8 km — no tight clustering. */
export const spacedTurnRoute: ParsedRoute = {
  distanceMeters: 8_000,
  durationSeconds: 1200,
  staticDurationSeconds: 1100,
  polyline: "encoded_spaced_turn_polyline",
  bounds: {
    southwest: { lat: 40.71, lng: -74.01 },
    northeast: { lat: 40.72, lng: -73.99 },
  },
  steps: [
    {
      distanceMeters: 500,
      staticDurationSeconds: 90,
      maneuver: "DEPART",
      navigationInstruction: "Head east on Main St",
    },
    {
      distanceMeters: 1_500,
      staticDurationSeconds: 120,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto 1st Ave",
    },
    {
      distanceMeters: 1_500,
      staticDurationSeconds: 120,
      maneuver: "TURN_RIGHT",
      navigationInstruction: "Turn right onto Oak St",
    },
    {
      distanceMeters: 1_500,
      staticDurationSeconds: 120,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto Pine St",
    },
    {
      distanceMeters: 1_500,
      staticDurationSeconds: 120,
      maneuver: "TURN_SHARP_RIGHT",
      navigationInstruction: "Sharp right onto Elm St",
    },
    {
      distanceMeters: 1_500,
      staticDurationSeconds: 120,
      maneuver: "TURN_LEFT",
      navigationInstruction: "Turn left onto Cedar Ave",
    },
  ],
};

/** Single isolated merge — should NOT trigger clustered interchange reason. */
export const singleMergeRoute: ParsedRoute = {
  distanceMeters: 50_000,
  durationSeconds: 1800,
  staticDurationSeconds: 1800,
  polyline: "encoded_single_merge_polyline",
  bounds: {
    southwest: { lat: 25.7, lng: -80.3 },
    northeast: { lat: 26.0, lng: -80.1 },
  },
  steps: [
    {
      distanceMeters: 40_000,
      staticDurationSeconds: 1400,
      maneuver: "DEPART",
      navigationInstruction: "Head north on I-95",
    },
    {
      distanceMeters: 5_000,
      staticDurationSeconds: 200,
      maneuver: "MERGE",
      navigationInstruction: "Merge onto I-295",
    },
    {
      distanceMeters: 5_000,
      staticDurationSeconds: 200,
      maneuver: "STRAIGHT",
      navigationInstruction: "Continue on I-295",
    },
  ],
};
