import { describe, expect, it, beforeEach } from "vitest";
import { Cl, cvToValue } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const client = accounts.get("wallet_1")!;
const freelancer = accounts.get("wallet_2")!;
const other = accounts.get("wallet_4")!;

function getValue(val: any): any {
    if (val && typeof val === 'object' && 'value' in val) {
        if (val.type === 'uint') return BigInt(val.value);
        if (val.type === 'principal') return val.value;
        if (val.type.startsWith('(string')) return val.value;
        return val.value; // generic unwrap check (e.g. some)
    }
    return val;
}

// Recursive unwrapper for deep structures
function unwrap(val: any): any {
    const v = getValue(val);
    if (v && typeof v === 'object' && !Array.isArray(v)) {
        // If it's a tuple, unwrap values
        const newObj: any = {};
        for (const k in v) {
            newObj[k] = unwrap(v[k]);
        }
        return newObj;
    }
    return v;
}

describe("MilestoneXYZ - Project Management", () => {
    beforeEach(() => {
        simnet.setEpoch("3.0");
    });

    describe("Project Creation", () => {
        it("should create a project with valid parameters", () => {
            const totalBudget = 100_000_000n; // 100 STX
            const deadline = simnet.blockHeight + 1000;
            const milestonesCount = 3n;

            const { result } = simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Mobile App Development"),
                    Cl.stringUtf8("Build a mobile app for iOS and Android"),
                    Cl.uint(totalBudget),
                    Cl.uint(deadline),
                    Cl.stringAscii("development"),
                    Cl.uint(milestonesCount),
                ],
                client
            );

            expect(result).toBeOk(Cl.uint(1));

            const { result: projectData } = simnet.callReadOnlyFn(
                "milestone",
                "get-project",
                [Cl.uint(1)],
                client
            );

            expect(projectData.type).toBe('some');
            const raw = cvToValue((projectData as any).value);
            const project = unwrap(raw);

            expect(project.client).toBe(client);
            expect(project.title).toBe("Mobile App Development");
            expect(project["total-budget"]).toBe(totalBudget);
            expect(project["escrow-balance"]).toBe(totalBudget);
            expect(project.status).toBe("open");
        });

        it("should fail to create project with insufficient budget", () => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Small Project"),
                    Cl.stringUtf8("Too small"),
                    Cl.uint(5_000_000),
                    Cl.uint(simnet.blockHeight + 1000),
                    Cl.stringAscii("design"),
                    Cl.uint(1),
                ],
                client
            );
            expect(result).toBeErr(Cl.uint(107)); // ERR-INVALID-AMOUNT
        });

        it("should fail to create project with past deadline", () => {
            simnet.mineEmptyBlocks(100);
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Past Project"),
                    Cl.stringUtf8("Deadline in the past"),
                    Cl.uint(100_000_000),
                    Cl.uint(simnet.blockHeight - 1),
                    Cl.stringAscii("design"),
                    Cl.uint(1),
                ],
                client
            );
            expect(result).toBeErr(Cl.uint(106)); // ERR-DEADLINE-PASSED
        });

        it("should collect client fee on project creation", () => {
            const totalBudget = 100_000_000n;
            const clientFee = 1_000_000n; // 1%

            const clientBalanceBefore = simnet.getAssetsMap().get("STX")?.get(client) || 0n;

            simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Fee Test"),
                    Cl.stringUtf8("Testing fee collection"),
                    Cl.uint(totalBudget),
                    Cl.uint(simnet.blockHeight + 1000),
                    Cl.stringAscii("design"),
                    Cl.uint(1),
                ],
                client
            );

            const clientBalanceAfter = simnet.getAssetsMap().get("STX")?.get(client) || 0n;
            const expectedDeduction = totalBudget + clientFee;
            expect(clientBalanceBefore - clientBalanceAfter).toBe(expectedDeduction);
        });
    });

    describe("Accept Proposal", () => {
        let projectId: number;

        beforeEach(() => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Test Project"),
                    Cl.stringUtf8("For proposal testing"),
                    Cl.uint(100_000_000),
                    Cl.uint(simnet.blockHeight + 1000),
                    Cl.stringAscii("development"),
                    Cl.uint(3),
                ],
                client
            );
            projectId = Number(getValue((result as any).value));
        });

        it("should accept proposal and assign freelancer", () => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "accept-proposal",
                [Cl.uint(projectId), Cl.principal(freelancer)],
                client
            );

            expect(result).toBeOk(Cl.bool(true));

            const { result: projectData } = simnet.callReadOnlyFn(
                "milestone",
                "get-project",
                [Cl.uint(projectId)],
                client
            );

            const project = unwrap(cvToValue((projectData as any).value));
            expect(getValue(project.freelancer)).toBe(freelancer); // project.freelancer might be wrapped
            expect(project.status).toBe("active");
        });

        it("should fail when non-client tries to accept proposal", () => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "accept-proposal",
                [Cl.uint(projectId), Cl.principal(freelancer)],
                other
            );
            expect(result).toBeErr(Cl.uint(100)); // ERR-NOT-AUTHORIZED
        });
    });

    describe("Cancel Project", () => {
        let projectId: number;

        beforeEach(() => {
            const { result } = simnet.callPublicFn(
                "milestone",
                "create-project",
                [
                    Cl.stringUtf8("Cancellable Project"),
                    Cl.stringUtf8("To be cancelled"),
                    Cl.uint(100_000_000),
                    Cl.uint(simnet.blockHeight + 1000),
                    Cl.stringAscii("design"),
                    Cl.uint(2),
                ],
                client
            );
            projectId = Number(getValue((result as any).value));
        });

        it("should cancel project before work starts", () => {
            const clientBalanceBefore = simnet.getAssetsMap().get("STX")?.get(client) || 0n;

            const { result } = simnet.callPublicFn(
                "milestone",
                "cancel-project",
                [Cl.uint(projectId)],
                client
            );
            expect(result).toBeOk(Cl.bool(true));

            const { result: projectData } = simnet.callReadOnlyFn(
                "milestone",
                "get-project",
                [Cl.uint(projectId)],
                client
            );

            const project = unwrap(cvToValue((projectData as any).value));
            expect(project.status).toBe("cancelled");
            expect(project["escrow-balance"]).toBe(0n);

            const clientBalanceAfter = simnet.getAssetsMap().get("STX")?.get(client) || 0n;
            expect(clientBalanceAfter).toBeGreaterThan(clientBalanceBefore);
        });
    });
});
