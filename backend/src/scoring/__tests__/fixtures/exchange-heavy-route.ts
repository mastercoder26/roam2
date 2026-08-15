import type { ParsedRoute } from "../../../types.js";

/** I-95 style exchange-heavy corridor with many ramps and merges */
export const exchangeHeavyRoute: ParsedRoute = {
  distanceMeters: 80_467, // ~50 miles
  durationSeconds: 4200,
  staticDurationSeconds: 3600,
  polyline: "encoded_exchange_heavy_polyline",
  bounds: {
    southwest: { lat: 39.0, lng: -77.5 },
    northeast: { lat: 39.8, lng: -76.2 },
  },
  steps: [
    { distanceMeters: 8000, staticDurationSeconds: 360, maneuver: "DEPART", navigationInstruction: "Head north on I-95" },
    { distanceMeters: 1200, staticDurationSeconds: 90, maneuver: "RAMP_RIGHT", navigationInstruction: "Exit 41 toward Baltimore" },
    { distanceMeters: 900, staticDurationSeconds: 70, maneuver: "MERGE", navigationInstruction: "Merge onto I-895 North" },
    { distanceMeters: 6000, staticDurationSeconds: 300, maneuver: "STRAIGHT", navigationInstruction: "Continue on I-895" },
    { distanceMeters: 1100, staticDurationSeconds: 85, maneuver: "RAMP_LEFT", navigationInstruction: "Exit toward I-695 West" },
    { distanceMeters: 800, staticDurationSeconds: 60, maneuver: "MERGE", navigationInstruction: "Merge onto I-695 West" },
    { distanceMeters: 7000, staticDurationSeconds: 320, maneuver: "STRAIGHT", navigationInstruction: "Continue on I-695" },
    { distanceMeters: 1000, staticDurationSeconds: 80, maneuver: "RAMP_RIGHT", navigationInstruction: "Exit 23 toward I-95 North" },
    { distanceMeters: 750, staticDurationSeconds: 55, maneuver: "MERGE", navigationInstruction: "Merge onto I-95 North" },
    { distanceMeters: 15000, staticDurationSeconds: 650, maneuver: "STRAIGHT", navigationInstruction: "Continue on I-95" },
    { distanceMeters: 900, staticDurationSeconds: 75, maneuver: "RAMP_LEFT", navigationInstruction: "Exit 89 toward I-495" },
    { distanceMeters: 850, staticDurationSeconds: 65, maneuver: "MERGE", navigationInstruction: "Merge onto I-495 West" },
    { distanceMeters: 12000, staticDurationSeconds: 520, maneuver: "STRAIGHT", navigationInstruction: "Continue on I-495" },
    { distanceMeters: 950, staticDurationSeconds: 80, maneuver: "RAMP_RIGHT", navigationInstruction: "Exit toward I-270 North" },
    { distanceMeters: 700, staticDurationSeconds: 55, maneuver: "MERGE", navigationInstruction: "Merge onto I-270 North" },
    { distanceMeters: 15000, staticDurationSeconds: 600, maneuver: "STRAIGHT", navigationInstruction: "Continue on I-270" },
    { distanceMeters: 1217, staticDurationSeconds: 115, maneuver: "RAMP_RIGHT", navigationInstruction: "Take exit toward destination" },
  ],
};
