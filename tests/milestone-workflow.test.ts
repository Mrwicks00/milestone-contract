import { describe, expect, it, beforeEach } from "vitest";
import { Cl, cvToValue } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const client = accounts.get("wallet_1")!;
const freelancer = accounts.get("wallet_2")!;

function getValue(val: any): any {
    if (val && typeof val === 'object' && 'value' in val) {
        if (val.type === 'uint') return BigInt(val.value);
        if (val.type === 'principal') return val.value;
        if (val.type.startsWith('(string')) return val.value;
        return getValue(val.value); // recursive check
    }
    return val;
}

function unwrap(val: any): any {
    const v = getValue(val);
    if (v && typeof v === 'object' && !Array.isArray(v)) {
        if ('type' in v) return unwrap(v); // still wrapped?
        const newObj: any = {};
        for (const k in v) {
            newObj[k] = unwrap(v[k]);
        }
        return newObj;
    }
    return v;
}

describe("MilestoneXYZ - Milestones & Escrow", () => {
    let projectId: number;

    beforeEach(() => {
        simnet.setEpoch("3.0");
        const createResult = simnet.callPublicFn(
            "milestone",
            "create-project",
            [
                Cl.stringUtf8("Test Project"),
                Cl.stringUtf8("Project for milestone testing"),
                Cl.uint(300_000_000),
                Cl.uint(simnet.blockHeight + 1000),
                Cl.stringAscii("development"),
                Cl.uint(3),
            ],
            client
        );
        projectId = Number(getValue((createResult.result as any).value));

        simnet.callPublicFn(
            "milestone",
            "accept-proposal",
            [Cl.uint(projectId), Cl.principal(freelancer)],
            client
        );
    });

    describe("Milestone Creation", () => {
        it("should create a milestone with valid parameters", () => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-milestone",
                [
                    Cl.uint(projectId),
                    Cl.stringUtf8("Design Phase"),
                    Cl.stringUtf8("Complete UI/UX designs"),
                    Cl.uint(100_000_000),
                    Cl.uint(simnet.blockHeight + 500),
                ],
                client
            );

            expect(result).toBeOk(Cl.uint(1));

            const { result: milestoneData } = simnet.callReadOnlyFn(
                "milestone",
                "get-milestone",
                [Cl.uint(1)],
                client
            );

            const milestone = unwrap(cvToValue((milestoneData as any).value));
            expect(milestone["project-id"]).toBe(BigInt(projectId));
            expect(milestone.title).toBe("Design Phase");
            expect(milestone["payment-amount"]).toBe(100_000_000n);
        });

        it("should fail to create milestone exceeding escrow balance", () => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-milestone",
                [
                    Cl.uint(projectId),
                    Cl.stringUtf8("Too Expensive"),
                    Cl.stringUtf8("Exceeds budget"),
                    Cl.uint(500_000_000),
                    Cl.uint(simnet.blockHeight + 500),
                ],
                client
            );
            expect(result).toBeErr(Cl.uint(104));
        });
    });

    describe("Milestone Submission", () => {
        let milestoneId: number;

        beforeEach(() => {
            const res = simnet.callPublicFn(
                "milestone",
                "create-milestone",
                [
                    Cl.uint(projectId),
                    Cl.stringUtf8("Dev Phase"),
                    Cl.stringUtf8("Dev work"),
                    Cl.uint(100_000_000),
                    Cl.uint(simnet.blockHeight + 500),
                ],
                client
            );
            milestoneId = Number(getValue((res.result as any).value));
        });

        it("should submit milestone with deliverable hash", () => {
            const deliverableHash = new Uint8Array(64).fill(1);
            const { result } = simnet.callPublicFn(
                "milestone",
                "submit-milestone",
                [Cl.uint(milestoneId), Cl.buffer(deliverableHash)],
                freelancer
            );
            expect(result).toBeOk(Cl.bool(true));

            const { result: data } = simnet.callReadOnlyFn("milestone", "get-milestone", [Cl.uint(milestoneId)], client);
            const m = unwrap(cvToValue((data as any).value));
            expect(m.status).toBe("submitted");
        });
    });

    describe("Milestone Approval & Payment", () => {
        let milestoneId: number;

        beforeEach(() => {
            const res = simnet.callPublicFn(
                "milestone",
                "create-milestone",
                [Cl.uint(projectId), Cl.stringUtf8("Payment Test"), Cl.stringUtf8("Test"), Cl.uint(100_000_000), Cl.uint(simnet.blockHeight + 500)], client
            );
            milestoneId = Number(getValue((res.result as any).value));
            const hash = new Uint8Array(64).fill(1);
            simnet.callPublicFn("milestone", "submit-milestone", [Cl.uint(milestoneId), Cl.buffer(hash)], freelancer);
        });

        it("should approve milestone and release payment", () => {
            const before = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;
            const { result } = simnet.callPublicFn("milestone", "approve-milestone", [Cl.uint(milestoneId)], client);
            expect(result).toBeOk(Cl.bool(true));
            const after = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;
            expect(after).toBeGreaterThan(before);

            const { result: data } = simnet.callReadOnlyFn("milestone", "get-milestone", [Cl.uint(milestoneId)], client);
            const m = unwrap(cvToValue((data as any).value));
            expect(m.status).toBe("approved");
        });

        it("should deduct platform fee from payment", () => {
            // Platform fee 3% for bronze.
            // 100 STX -> 3 STX fee. Net 97 STX.
            const before = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;
            simnet.callPublicFn("milestone", "approve-milestone", [Cl.uint(milestoneId)], client);
            const after = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;
            expect(after - before).toBe(97_000_000n);
        });
    });
});
