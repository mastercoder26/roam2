import type { Request, Response } from "express";
import { describe, expect, it, vi } from "vitest";
import { ClerkAccountDeletionError } from "../../auth/errors.js";

const { deleteClerkUserMock, deleteUserMock, findByIdMock, toPublicUserMock } = vi.hoisted(() => ({
  deleteClerkUserMock: vi.fn(),
  deleteUserMock: vi.fn(),
  findByIdMock: vi.fn(),
  toPublicUserMock: vi.fn(),
}));

vi.mock("../../auth/client.js", () => ({ deleteClerkUser: deleteClerkUserMock }));
vi.mock("../../db/repositories/users.js", () => ({
  deleteUser: deleteUserMock,
  findById: findByIdMock,
  toPublicUser: toPublicUserMock,
}));

import { handleDeleteAccount, handleMe } from "../auth.js";

function responseDouble() {
  const response = {
    statusCode: 200,
    body: undefined as unknown,
    status(code: number) {
      response.statusCode = code;
      return response;
    },
    json(body: unknown) {
      response.body = body;
      return response;
    },
    end() {
      return response;
    },
  };
  return response as unknown as Response & { statusCode: number; body: unknown };
}

const request = {
  user: {
    id: "00000000-0000-0000-0000-000000000001",
    email: "driver@example.com",
    clerkUserId: "user_clerk_123",
  },
} as unknown as Request;

describe("Clerk-backed account handlers", () => {
  it("does not delete locally when Clerk deletion fails", async () => {
    deleteClerkUserMock.mockRejectedValueOnce(new ClerkAccountDeletionError(new Error("Clerk unavailable")));
    const response = responseDouble();

    await handleDeleteAccount(request, response);

    expect(response.statusCode).toBe(503);
    expect(response.body).toMatchObject({ code: "SERVICE_UNAVAILABLE" });
    expect(deleteUserMock).not.toHaveBeenCalled();
  });

  it("deletes Clerk first, then cascades the local user", async () => {
    deleteClerkUserMock.mockResolvedValueOnce(undefined);
    deleteUserMock.mockResolvedValueOnce(undefined);
    const response = responseDouble();

    await handleDeleteAccount(request, response);

    expect(response.statusCode).toBe(204);
    expect(deleteClerkUserMock).toHaveBeenCalledWith("user_clerk_123");
    expect(deleteUserMock).toHaveBeenCalledWith(request.user?.id);
    expect(deleteClerkUserMock.mock.invocationCallOrder[0]).toBeLessThan(deleteUserMock.mock.invocationCallOrder[0]);
  });

  it("returns the local user for /api/auth/me", async () => {
    const localUser = { id: request.user?.id, email: "driver@example.com" };
    findByIdMock.mockResolvedValueOnce(localUser);
    toPublicUserMock.mockReturnValueOnce({ id: localUser.id, email: localUser.email, displayName: null });
    const response = responseDouble();

    await handleMe(request, response);

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual({
      user: { id: localUser.id, email: localUser.email, displayName: null },
    });
  });
});
