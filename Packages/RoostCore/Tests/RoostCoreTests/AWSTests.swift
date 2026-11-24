import Foundation
import Testing
@testable import RoostCore

@Suite struct INIFileTests {
    @Test func setsKeysInPlaceAndAppendsSections() {
        var file = INIFile(text: "# comment\n[a]\nx = 1\n\n[b]\ny = 2\n")
        file.set("x", "9", in: "a")
        file.set("z", "3", in: "a")
        file.set("k", "v", in: "c")
        #expect(file.text == "# comment\n[a]\nx = 9\nz = 3\n\n[b]\ny = 2\n\n[c]\nk = v\n")
        #expect(file.values(in: "a") == ["x": "9", "z": "3"])
    }

    @Test func removesSectionsAndKeys() {
        var file = INIFile(text: "[a]\nx = 1\n\n[b]\ny = 2\nw = 4\n")
        file.removeKey("w", in: "b")
        let removedA = file.removeSection("a")
        let removedMissing = file.removeSection("missing")
        #expect(removedA && !removedMissing)
        #expect(file.text == "[b]\ny = 2\n")
    }
}

@Suite struct AWSTests {
    static let config = """
    [profile vaulted]
    region = us-east-1
    credential_process = /opt/homebrew/bin/aws-vault --backend=keychain --keychain=login exec vaulted --json

    [profile sso-dev]
    sso_start_url = https://example.awsapps.com/start
    sso_region = us-east-1
    region = eu-west-1

    [sso-session shared]
    sso_start_url = https://example.awsapps.com/start

    [default]
    region = ap-south-1
    """

    static let credentials = """
    [temp]
    aws_access_key_id = ASIAEXAMPLE
    aws_secret_access_key = secret
    aws_session_token = token

    [plain]
    aws_access_key_id = AKIAEXAMPLE
    aws_secret_access_key = secret
    """

    func files(config: String = AWSTests.config, credentials: String = AWSTests.credentials) throws -> AWSFiles {
        let folder = try makeTempDirectory()
        let files = AWSFiles(config: folder.appendingPathComponent("config"), credentials: folder.appendingPathComponent("credentials"))
        try write(config, to: files.config)
        try write(credentials, to: files.credentials)
        return files
    }

    @Test func classifiesEveryProfileKind() throws {
        let profiles = try AWS.profiles(in: files())
        #expect(profiles.map(\.name) == ["vaulted", "sso-dev", "default", "temp", "plain"])
        #expect(profiles.map(\.kind) == [.vault, .sso, .none, .temporary, .accessKey])
        #expect(profiles.first { $0.name == "sso-dev" }?.region == "eu-west-1")
    }

    @Test func writesAndRefreshesTemporaryCredentials() throws {
        let files = try files()
        try AWS.setTemporaryCredentials(
            name: "gbi", region: "us-east-1", accessKeyID: "ASIANEW", secretAccessKey: "s1", sessionToken: "t1", files: files
        )
        try AWS.setTemporaryCredentials(name: "gbi", region: "", accessKeyID: "ASIANEW2", secretAccessKey: "s2", sessionToken: "t2", files: files)

        let credentials = try INIFile.read(files.credentials)
        #expect(credentials.values(in: "gbi") == ["aws_access_key_id": "ASIANEW2", "aws_secret_access_key": "s2", "aws_session_token": "t2"])
        #expect(try INIFile.read(files.config).values(in: "profile gbi")["region"] == "us-east-1")
        let permissions = try FileManager.default.attributesOfItem(atPath: files.credentials.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(throws: RoostError.profileExists("vaulted")) {
            try AWS.setTemporaryCredentials(name: "vaulted", region: "", accessKeyID: "a", secretAccessKey: "b", sessionToken: "c", files: files)
        }
    }

    @Test func addsSSOProfileWithoutKeys() throws {
        let files = try files()
        try AWS.addSSOProfile(
            name: "prod", region: "us-east-1", startURL: "https://x.awsapps.com/start", ssoRegion: "us-east-1",
            accountID: "123456789012", roleName: "ReadOnly", files: files
        )
        #expect(try AWS.profiles(in: files).first { $0.name == "prod" }?.kind == .sso)
        #expect(try INIFile.read(files.credentials).hasSection("prod") == false)
        #expect(throws: RoostError.profileExists("prod")) {
            try AWS.addSSOProfile(name: "prod", region: "", startURL: "", ssoRegion: "", accountID: "", roleName: "", files: files)
        }
        #expect(throws: RoostError.invalidName("bad name")) {
            try AWS.addSSOProfile(name: "bad name", region: "", startURL: "", ssoRegion: "", accountID: "", roleName: "", files: files)
        }
    }

    @Test func removesProfileFromBothFiles() async throws {
        let files = try files(config: "[profile plain]\nregion = us-east-1\n")
        let plain = try #require(try AWS.profiles(in: files).first { $0.name == "plain" })

        try await AWS.removeProfile(plain, files: files)

        #expect(try AWS.profiles(in: files).map(\.name) == ["temp"])
        #expect(try String(contentsOf: files.config, encoding: .utf8).isEmpty)
    }

    @Test func parsesCallerIdentity() {
        let output = "{\n  \"UserId\": \"AID\",\n  \"Account\": \"123456789012\",\n  \"Arn\": \"arn:aws:iam::123456789012:user/me\"\n}"
        #expect(AWS.parseIdentity(output) == .signedIn(account: "123456789012", arn: "arn:aws:iam::123456789012:user/me"))
        #expect(AWS.parseIdentity("An error occurred (ExpiredToken)") == nil)
    }
}

@Suite struct SecretScanTests {
    @Test func findsCommonCredentials() {
        #expect(SecretScan.findings(in: "key AKIAABCDEFGHIJKLMNOP here") == ["AWS access key"])
        #expect(SecretScan.findings(in: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789") == ["GitHub token"])
        #expect(SecretScan.findings(in: "https://user:pass@example.com/x").isEmpty)
        #expect(SecretScan.findings(in: "plain words, ~/path and https://example.com").isEmpty)
        #expect(SecretScan.findings(in: "https://deploy:Zq83kd02Lmx@db.acme.io/prod") == ["password in URL"])
        #expect(SecretScan.findings(in: "postgres://user:Zq83kd02Lmx@localhost:5432/db").isEmpty)
        #expect(SecretScan.findings(in: "redis://app:password@cache.acme.io").isEmpty)
        #expect(SecretScan.findings(in: "mysql://root:${DB_PASS}@db.acme.io").isEmpty)
        #expect(SecretScan.findings(in: "AWS's documented key AKIAIOSFODNN7EXAMPLE").isEmpty)
        #expect(SecretScan.findings(in: #"Bash(export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMIK7MDENGbPxRfiCYab12cd34ef")"#) == ["secret value"])
        #expect(SecretScan.findings(in: "db_password: Zq83kd02LmxPq19sWv77") == ["secret value"])
        #expect(SecretScan.findings(in: "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY").isEmpty)
        #expect(SecretScan.findings(in: "API_KEY=your-api-key-here-12345").isEmpty)
        #expect(SecretScan.findings(in: "GITHUB_TOKEN=${GITHUB_TOKEN}").isEmpty)
    }

    @Test func recognisesSecretNamesAndPlaceholders() {
        #expect(SecretScan.isSecretName("GITHUB_TOKEN"))
        #expect(SecretScan.isSecretName("Authorization"))
        #expect(!SecretScan.isSecretName("EDITOR"))
        #expect(SecretScan.placeholders(in: "a {{secret:B_1}} c {{secret:A}} {{secret:A}}") == ["A", "B_1"])
    }
}
