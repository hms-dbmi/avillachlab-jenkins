@Grab(group = 'software.amazon.awssdk', module = 'sts', version = '2.27.12')
@Grab(group = 'software.amazon.awssdk', module = 'secretsmanager', version = '2.27.12')
@Grab(group = 'software.amazon.awssdk', module = 'regions', version = '2.27.12')

import software.amazon.awssdk.services.sts.StsClient
import software.amazon.awssdk.services.sts.model.AssumeRoleRequest
import software.amazon.awssdk.services.sts.model.AssumeRoleResponse
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient
import software.amazon.awssdk.services.secretsmanager.model.ListSecretsRequest
import software.amazon.awssdk.regions.Region

class AWSHelper {

    private def logger
    private String app_acct_id
    private String role_name
    private transient AwsSessionCredentials credentials

    AWSHelper(String app_acct_id, String role_name, logger) {
        this.logger = logger
        this.app_acct_id = app_acct_id
        this.role_name = role_name
    }

    AwsSessionCredentials assumeRole() {
        String role_arn = "arn:aws:iam::${this.app_acct_id}:role/${this.role_name}"
        logger("Role ARN constructed: ${role_arn.toString()}")
        logger("Starting assumeRole with roleArn: ${role_arn.toString()}")

        StsClient stsClient = StsClient.builder().region(Region.US_EAST_1).build()
        logger("Created STS client.")

        AssumeRoleRequest assumeRoleRequest = AssumeRoleRequest.builder()
                .roleArn(role_arn)
                .roleSessionName("teardown-rebuild")
                .build()
        logger("AssumeRole request prepared.")

        AssumeRoleResponse assumeRoleResult = stsClient.assumeRole(assumeRoleRequest)
        logger("AssumeRole executed. Result obtained.")

        AwsSessionCredentials sessionCredentials = AwsSessionCredentials.create(
                assumeRoleResult.credentials().accessKeyId(),
                assumeRoleResult.credentials().secretAccessKey(),
                assumeRoleResult.credentials().sessionToken()
        )

        this.credentials = sessionCredentials
    }

    def fetchAwsCredentials() {
        if (!this.credentials) {
            assumeRole()
        }
        return [
                this.credentials.accessKeyId(),
                this.credentials.secretAccessKey(),
                this.credentials.sessionToken()
        ]
    }

    List<String> getAllSecretsNames() {
        logger("Listing all secrets.")
        SecretsManagerClient secretsManagerClient

        if (!this.credentials) {
            logger("Credentials not found. Assuming role.")
            assumeRole()
        } else {
            logger("Using provided credentials.")
        }

        secretsManagerClient = SecretsManagerClient.builder()
                .region(Region.US_EAST_1)
                .credentialsProvider(StaticCredentialsProvider.create(this.credentials))
                .build()

        List<String> allSecretNames = []
        String nextToken = null

        try {
            while (true) {
                ListSecretsRequest listSecretsRequest = ListSecretsRequest.builder()
                        .nextToken(nextToken)
                        .build()

                def listSecretsResult = secretsManagerClient.listSecrets(listSecretsRequest)
                def secretList = listSecretsResult.secretList()
                allSecretNames.addAll(secretList.collect { it.name() })

                nextToken = listSecretsResult.nextToken()
                if (nextToken == null) {
                    break
                }
            }

            return allSecretNames
        } catch (Exception e) {
            logger("Error while listing secrets: ${e.message.toString()}")
            throw e
        }
    }

}