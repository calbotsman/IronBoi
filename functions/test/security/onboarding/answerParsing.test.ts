import { describe, expect, it } from "vitest";
import { needsClearance, parseDays, parseTime } from "../../../src/onboarding/flow.js";

describe("parseDays", () => {
  it("reads named days, weekdays, weekends and counts", () => {
    expect(parseDays("Mondays, Wednesdays and Fridays")).toEqual(["Mon", "Wed", "Fri"]);
    expect(parseDays("tue thu")).toEqual(["Tue", "Thu"]);
    expect(parseDays("weekdays")).toEqual(["Mon", "Tue", "Wed", "Thu", "Fri"]);
    expect(parseDays("saturday and weekdays")).toEqual(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]);
    expect(parseDays("3 days a week")).toEqual(["Mon", "Wed", "Fri"]);
    expect(parseDays("whenever")).toEqual([]);
  });
});

describe("parseTime", () => {
  it("reads clock times and everyday phrases", () => {
    expect(parseTime("Mon Wed Fri at 6pm")).toBe("18:00");
    expect(parseTime("6:30 am")).toBe("06:30");
    expect(parseTime("at 6")).toBe("18:00");
    expect(parseTime("at 7")).toBe("07:00");
    expect(parseTime("after work")).toBe("18:00");
    expect(parseTime("mornings before work")).toBe("07:00");
    // A day count is not a time.
    expect(parseTime("3 days")).toBeUndefined();
  });
});

describe("needsClearance", () => {
  it("catches the doctor / symptoms screen, not ordinary aches", () => {
    expect(needsClearance("A doctor told me to limit exercise")).toBe(true);
    expect(needsClearance("I get chest pain when I run")).toBe(true);
    expect(needsClearance("dizzy sometimes")).toBe(true);
    expect(needsClearance("my left knee is sore")).toBe(false);
    expect(needsClearance("nothing")).toBe(false);
  });
});

describe("older app builds", () => {
  it("still finish onboarding with the six answers they send", async () => {
    // Covered end to end in sixQuestions.test.ts; here just the contract:
    // sex, height and weight are optional on the server.
    const { readFileSync } = await import("node:fs");
    const source = readFileSync(new URL("../../../src/onboarding/flow.ts", import.meta.url), "utf8");
    const required = source.slice(source.indexOf("const REQUIRED_FIELDS"), source.indexOf("] as const;"));
    for (const field of ["sexOrGender", "heightCm", "weightKg"]) expect(required).not.toContain(`"${field}"`);
  });
});
