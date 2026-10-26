# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for forge.j: repository paths, ids and workflow claims.
# Run with:
#
#     jennifer test src/forge_test.j
#
# Hermetic: the one network call is pointed at a closed loopback port.

use testing;

func testARepositoryPathIsReadFromThePathOrAGithubUrl() {
    testing.assertEqual(repositoryPath("acme/deck-routeros"), "acme/deck-routeros");
    testing.assertEqual(repositoryPath(" https://github.com/acme/deck/ "), "acme/deck");
    testing.assertEqual(repositoryPath("https://GitHub.com/acme/deck.git"), "acme/deck");
    testing.assertEqual(repositoryPath("git@github.com:acme/deck.git"), "acme/deck");
}

func testAnythingButOwnerAndNameIsNotARepositoryPath() {
    testing.assertEqual(repositoryPath("acme"), "");
    testing.assertEqual(repositoryPath("acme/deck/extra"), "");
    testing.assertEqual(repositoryPath("acme/../deck"), "");
    testing.assertEqual(repositoryPath("ac me/deck"), "");
    testing.assertEqual(repositoryPath("https://gitlab.com/acme/deck"), "");
    testing.assertEqual(repositoryPath("/deck"), "");
}

func testARepositoryIdIsDigitsOnly() {
    testing.assertTrue(isRepositoryId("123456789"));
    testing.assertFalse(isRepositoryId(""));
    testing.assertFalse(isRepositoryId("12a"));
    testing.assertFalse(isRepositoryId("1234567890123456789"));
}

func testGithubsAnswerGivesTheIdAndItsOwnSpelling() {
    def r as Repository init repositoryOf(
        200,
        '{"id": 123456789, "full_name": "Acme/Deck-RouterOS"}',
        "acme/deck-routeros");
    testing.assertEqual($r.error, "");
    testing.assertEqual($r.id, "123456789");
    testing.assertEqual($r.path, "Acme/Deck-RouterOS");
}

func testAMissingOrPrivateRepositoryPointsAtTheIdFlag() {
    def r as Repository init repositoryOf(404, '{"message": "Not Found"}', "acme/secret");
    testing.assertEqual($r.id, "");
    testing.assertContains($r.error, "no public repository acme/secret");
    testing.assertContains($r.error, "--repository-id");
}

# A float or a string id would be registered as text that matches no token's
# `repository_id`, so it is refused here.
func testAnIdThatIsNotAnIntegerIsRefused() {
    testing.assertContains(repositoryOf(200, '{"id": "123"}', "a/b").error, "no repository id");
    testing.assertContains(repositoryOf(200, '{"id": 1.5}', "a/b").error, "no repository id");
    testing.assertContains(repositoryOf(200, "<html>", "a/b").error, "not JSON");
    testing.assertContains(repositoryOf(500, "", "a/b").error, "answered 500");
}

func testAnUnreachableForgeIsReportedNotThrown() {
    def r as Repository init githubRepository("http://127.0.0.1:1", "acme/deck");
    testing.assertContains($r.error, "could not reach GitHub");
}

func testAGithubWorkflowGetsItsRepositoryInFront() {
    def want as string init "acme/deck/.github/workflows/publish.yml";
    testing.assertEqual(workflowClaim(GITHUB_ACTIONS, "acme/deck", "publish.yml").workflow, $want);
    testing.assertEqual(
        workflowClaim(GITHUB_ACTIONS, "acme/deck", ".github/workflows/publish.yml").workflow,
        $want);
}

# A reusable workflow lives in another repository and is named with it.
func testAWorkflowNamingARepositoryIsKept() {
    def w as string init "acme/shared/.github/workflows/release.yml";
    testing.assertEqual(workflowClaim(GITHUB_ACTIONS, "acme/deck", $w).workflow, $w);
}

func testAGithubWorkflowElsewhereInTheTreeIsRefused() {
    testing.assertContains(
        workflowClaim(GITHUB_ACTIONS, "acme/deck", "ci/publish.yml").error,
        "give the file's name");
}

func testABareGithubWorkflowNeedsTheRepositoryPath() {
    def w as Workflow init workflowClaim(GITHUB_ACTIONS, "", "publish.yml");
    testing.assertContains($w.error, "needs the repository path");
}

func testOtherProvidersAndNoWorkflowPassThrough() {
    testing.assertEqual(workflowClaim("gitea-actions", "", "publish.yml").workflow, "publish.yml");
    def w as Workflow init workflowClaim(GITHUB_ACTIONS, "", " ");
    testing.assertEqual($w.workflow, "");
    testing.assertEqual($w.error, "");
}
