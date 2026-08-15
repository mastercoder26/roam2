import { describe, expect, it } from "vitest";
import { validateProfileUpdate } from "../profile.js";

describe("profile validation", () => {
  it("accepts partial last-write-wins updates", () => {
    expect(validateProfileUpdate({
      stage: "licensed",
      payload: { preferredTheme: "dark" },
    })).toEqual({
      stage: "licensed",
      payload: { preferredTheme: "dark" },
    });
  });

  it("rejects invalid stages and non-object payloads", () => {
    expect(() => validateProfileUpdate({ stage: "expert" })).toThrow();
    expect(() => validateProfileUpdate({ payload: "not-json" })).toThrow();
  });
});
