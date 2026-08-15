import type { LatLng } from "../types.js";
import { neutralTurns, type TurnExposure } from "./types.js";

const SIGNAL_MATCH_RADIUS_M = 25;

export interface TrafficSignalNode {
  lat: number;
  lon: number;
  tags?: Record<string, string>;
}

function metersBetween(a: LatLng, b: { lat: number; lng: number }): number {
  const latRad = ((a.lat + b.lat) / 2) * (Math.PI / 180);
  const dLat = (b.lat - a.lat) * 111_320;
  const dLng = (b.lng - a.lng) * 111_320 * Math.cos(latRad);
  return Math.sqrt(dLat * dLat + dLng * dLng);
}

/**
 * Classifies each left turn as protected (a mapped traffic signal governs it)
 * or unprotected (the driver must judge a gap in oncoming traffic).
 *
 * A missing signal in OpenStreetMap could mean the turn is really unsignalized,
 * or that the area just isn't mapped in detail — guessing "unprotected" from
 * unmapped data would invent difficulty. `areaIsMapped` gates the result:
 * absence of a signal only counts as evidence once Overpass has actually
 * resolved road data for the corridor.
 *
 * Stop signs and yields don't count as protection — they control the turning
 * driver, not the oncoming traffic being turned across.
 */
export function determineTurnProtection(
  turnPoints: LatLng[],
  signalNodes: TrafficSignalNode[],
  areaIsMapped: boolean
): TurnExposure {
  if (turnPoints.length === 0) {
    return { ...neutralTurns(), available: true };
  }

  if (!areaIsMapped) {
    return neutralTurns();
  }

  const signals = signalNodes.filter((node) => node.tags?.highway === "traffic_signals");

  // One signal or several within the radius both mean the turn is signalized;
  // only the absence of any signal leaves the driver unprotected.
  const protectedLeftTurns = turnPoints.filter((turnPoint) =>
    signals.some((node) =>
      metersBetween(turnPoint, { lat: node.lat, lng: node.lon }) <= SIGNAL_MATCH_RADIUS_M
    )
  ).length;

  const unprotectedLeftTurns = turnPoints.length - protectedLeftTurns;

  return {
    available: true,
    unprotectedLeftTurns,
    protectedLeftTurns,
    unprotectedTurnShare: unprotectedLeftTurns / turnPoints.length,
  };
}
