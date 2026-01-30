import { describe, expect, it, beforeEach } from "vitest";
import { Cl, cvToValue } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const client = accounts.get("wallet_1")!;
const freelancer = accounts.get("wallet_2")!;
const arbitrator = accounts.get("wallet_3")!;

function getValue(val: any): any {
    if (val && typeof val === 'object' && 'value' in val) {
        if (val.type === 'uint') return BigInt(val.value);
        if (val.type === 'principal') return val.value;
        if (val.type.startsWith('(string')) return val.value;
        return getValue(val.value);
    }
    return val;
}

function unwrap(val: any): any {
    const v = getValue(val);
    if (v && typeof v === 'object' && !Array.isArray(v)) {
        if ('type' in v) return unwrap(v);
        const newObj: any = {};
        for (const k in v) {
            newObj[k] = unwrap(v[k]);
        }
        return newObj;
    }
    return v;
}

describe("MilestoneXYZ - Disputes & Reputation", () => {
    let projectId: number;
    let milestoneId: number;

    beforeEach(() => {
        simnet.setEpoch("3.0");
        const createResult = simnet.callPublicFn(
            "milestone",
            "create-project",
            [
                Cl.stringUtf8("Dispute Project"),
                Cl.stringUtf8("Desc"),
                Cl.uint(200_000_000),
                Cl.uint(simnet.blockHeight + 1000),
                Cl.stringAscii("development"),
                Cl.uint(2),
            ],
            client
        );
        projectId = Number(getValue((createResult.result as any).value));
        simnet.callPublicFn("milestone", "accept-proposal", [Cl.uint(projectId), Cl.principal(freelancer)], client);

        const mRes = simnet.callPublicFn("milestone", "create-milestone", [Cl.uint(projectId), Cl.stringUtf8("M1"), Cl.stringUtf8("D1"), Cl.uint(100_000_000), Cl.uint(simnet.blockHeight + 500)], client);
        milestoneId = Number(getValue((mRes.result as any).value));

        simnet.callPublicFn("milestone", "submit-milestone", [Cl.uint(milestoneId), Cl.buffer(new Uint8Array(64).fill(1))], freelancer);
    });

    describe("Resolve Dispute", () => {
        let disputeId: number;

        beforeEach(() => {
            const dRes = simnet.callPublicFn("milestone", "raise-dispute", [Cl.uint(milestoneId), Cl.stringUtf8("Reason"), Cl.buffer(new Uint8Array(64).fill(2))], client);
            disputeId = Number(getValue((dRes.result as any).value));
            simnet.callPublicFn("milestone", "assign-arbitrator", [Cl.uint(disputeId), Cl.principal(arbitrator)], deployer);
        });

        it("should resolve dispute with full payment to freelancer (minus fee)", () => {
            // 100 STX. Fee 5% = 5 STX.
            // Net 95 STX.
            // Freelancer alloc: 100 STX (from arbitrator).
            // Logic: (100 * 95) / 100 = 95 STX.
            const before = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;

            const { result } = simnet.callPublicFn("milestone", "resolve-dispute", [Cl.uint(disputeId), Cl.stringAscii("F wins"), Cl.uint(100_000_000)], arbitrator);
            expect(result).toBeOk(Cl.bool(true));

            const after = simnet.getAssetsMap().get("STX")?.get(freelancer) || 0n;
            expect(after - before).toBe(95_000_000n);
        });

        it("should collect dispute fee", () => {
            const treasury = accounts.get("deployer")!; // Treasury is initially deployer/owner
            const before = simnet.getAssetsMap().get("STX")?.get(treasury) || 0n;

            simnet.callPublicFn("milestone", "resolve-dispute", [Cl.uint(disputeId), Cl.stringAscii("F wins"), Cl.uint(100_000_000)], arbitrator);

            const after = simnet.getAssetsMap().get("STX")?.get(treasury) || 0n;
            expect(after - before).toBe(5_000_000n);
        });
    });

    describe("Reputation System", () => {
        it("should initialize reputation", () => {
            const { result } = simnet.callReadOnlyFn("milestone", "get-reputation", [Cl.principal(client)], client);
            expect(result.type).toBe('some');
            const rep = unwrap(cvToValue((result as any).value));
            expect(rep["total-projects"]).toBe(1n);
            expect(rep.tier).toBe("bronze");
        });

        it("should calculate tier", () => {
            const { result } = simnet.callReadOnlyFn("milestone", "get-user-tier", [Cl.principal(freelancer)], freelancer);
            expect(getValue(cvToValue(result))).toBe("bronze");
        });
    });

    describe("Rating System", () => {
        beforeEach(() => {
            // Approve M1
            simnet.callPublicFn("milestone", "approve-milestone", [Cl.uint(milestoneId)], client);
            // Create M2
            const m2Res = simnet.callPublicFn("milestone", "create-milestone", [Cl.uint(projectId), Cl.stringUtf8("M2"), Cl.stringUtf8("D2"), Cl.uint(100_000_000), Cl.uint(simnet.blockHeight + 500)], client);
            const m2Id = Number(getValue((m2Res.result as any).value));
            simnet.callPublicFn("milestone", "submit-milestone", [Cl.uint(m2Id), Cl.buffer(new Uint8Array(64).fill(1))], freelancer);
            simnet.callPublicFn("milestone", "approve-milestone", [Cl.uint(m2Id)], client);
            // Project should be Completed
        });

        it("should allow rating", () => {
            const { result } = simnet.callPublicFn("milestone", "rate-user",
                [Cl.uint(projectId), Cl.uint(500), Cl.stringUtf8("Great")],
                client
            );
            expect(result).toBeOk(Cl.bool(true));

            const { result: data } = simnet.callReadOnlyFn("milestone", "get-project-rating", [Cl.uint(projectId), Cl.principal(client)], client);
            const rating = unwrap(cvToValue((data as any).value));
            expect(rating.rating).toBe(500n);
        });
    });
});
