export class AuthConfigurationError extends Error {
  constructor(message = "Authentication is not configured") {
    super(message);
    this.name = "AuthConfigurationError";
  }
}

export class ClerkAccountDeletionError extends Error {
  constructor(readonly originalError: unknown) {
    super("The Clerk account could not be deleted.");
    this.name = "ClerkAccountDeletionError";
  }
}

export class LocalUserNotFoundError extends Error {
  constructor() {
    super("The authenticated local user could not be found.");
    this.name = "LocalUserNotFoundError";
  }
}
