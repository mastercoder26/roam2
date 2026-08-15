export interface UserRecord {
  id: string;
  clerkUserId: string | null;
  email: string;
  displayName: string | null;
  createdAt: Date;
  updatedAt: Date;
  emailVerifiedAt: Date | null;
  deletedAt?: Date | null;
}

export interface PublicUser {
  id: string;
  email: string;
  displayName: string | null;
}

export type DriverStage = "permit" | "provisional" | "licensed";

export interface ProfileRecord {
  userId: string;
  displayName: string | null;
  stage: DriverStage | null;
  payload: Record<string, unknown>;
  updatedAt: Date;
}

export interface DriveInputRecord {
  id: string;
  startedAt: Date;
  durationSeconds: number;
  distanceMeters: number;
  score: number;
  topSpeedMetersPerSecond: number;
  eventCount: number;
  recordingTimeZoneIdentifier: string | null;
  payload: Record<string, unknown>;
}

export interface DriveRecord extends DriveInputRecord {
  userId: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface DriveStats {
  totalDrives: number;
  totalDistanceMeters: number;
  totalDurationSeconds: number;
  averageScore: number | null;
}

export interface SavedRouteInputRecord {
  id: string;
  label: string;
  payload: Record<string, unknown>;
}

export interface SavedRouteRecord extends SavedRouteInputRecord {
  userId: string;
  createdAt: Date;
  updatedAt: Date;
}
