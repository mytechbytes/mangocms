pipeline {
    agent any

    parameters {
        choice(
            name: 'PIPELINE_ACTION',
            choices: ['BUILD_AND_DEPLOY', 'ROLLBACK'],
            description: 'BUILD_AND_DEPLOY: test, build, push, deploy. ROLLBACK: revert to previous tag.'
        )
        string(
            name: 'ROLLBACK_TAG',
            defaultValue: '',
            description: 'Required for ROLLBACK only. e.g. build-13'
        )
        string(
            name: 'COVERAGE_THRESHOLD',
            defaultValue: '80',
            description: 'Minimum test coverage % required to proceed.'
        )
        booleanParam(
            name: 'REBUILD_CI_IMAGE',
            defaultValue: false,
            description: 'Force rebuild and push of ci/Dockerfile. Set true when Elixir/OTP version changes.'
        )
    }

    environment {
        // ── Registry ──────────────────────────────────────────────────────────
        REGISTRY        = 'ap-mumbai-1.ocir.io'
        OCI_NAMESPACE   = 'bmsedjmf13c1'
        IMAGE_NAME      = 'mangocms'
        CONTAINER_NAME  = 'cms'
        ENV_VAR_NAME    = 'CMS_IMAGE_TAG'
        APP_URL         = 'https://cms.mytechbytes.in'

        // ── Production Server ─────────────────────────────────────────────────
        PRODUCTION_HOST = '161.118.161.178'
        PRODUCTION_USER = 'ubuntu'
        APPS_DIR        = '/home/ubuntu/apps'

        // ── Auto-computed Tags ────────────────────────────────────────────────
        BUILD_TAG       = "build-${env.BUILD_NUMBER}"
        IMAGE_VERSIONED = "${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:build-${env.BUILD_NUMBER}"
        IMAGE_LATEST    = "${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:latest"

        // ── CI Image ──────────────────────────────────────────────────────────
        // Custom image with git + build-base + hex + rebar pre-installed
        // Only rebuild ci/Dockerfile when Elixir/OTP version changes
        CI_IMAGE        = 'ap-mumbai-1.ocir.io/bmsedjmf13c1/mangocms-ci:latest'

        // ── Docker Run ────────────────────────────────────────────────────────
        // Reused across all Elixir stages
        // Mounts workspace so mix can read source files
        // Named volumes cache deps/_build across builds for speed
        DOCKER_RUN      = """docker run --rm \
            -v ${WORKSPACE}:/app \
            -v mangocms-deps:/app/deps \
            -v mangocms-build:/app/_build \
            -v mangocms-hex:/root/.hex \
            -v mangocms-mix:/root/.mix \
            -w /app \
            -e MIX_ENV=test \
            -e PGHOST=mangocms-postgres-ci \
            -e PGUSER=postgres \
            -e PGPASSWORD=postgres \
            -e SECRET_KEY_BASE=ci_secret_key_base_at_least_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
            --network mangocms-ci \
            ${CI_IMAGE}"""
    }

    options {
        // Keep last 10 builds — prevents disk bloat on Instance 1
        buildDiscarder(logRotator(numToKeepStr: '10'))

        // Abort if pipeline exceeds 30 minutes
        timeout(time: 30, unit: 'MINUTES')

        // Prevent concurrent builds — avoids race conditions on shared volumes
        disableConcurrentBuilds()

        // Add timestamps to all console output
        timestamps()
    }

    stages {

        // ─────────────────────────────────────────────────────────────────────
        // Stage 0: CI Image
        // Build and push the CI runner image from ci/Dockerfile if it does not
        // exist in OCIR yet, or if REBUILD_CI_IMAGE is checked.
        // This image is the base for all Elixir pipeline stages AND for the
        // production Dockerfile's build stages — so it must exist before either
        // can run.
        // ─────────────────────────────────────────────────────────────────────
        stage('CI Image') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ocir-credentials',
                        usernameVariable: 'OCIR_USER',
                        passwordVariable: 'OCIR_PASS'
                    )
                ]) {
                    sh '''
                        echo "── Logging in to OCIR ──"
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin

                        NEEDS_BUILD=false

                        if [ "${REBUILD_CI_IMAGE}" = "true" ]; then
                            echo "── REBUILD_CI_IMAGE=true — forcing rebuild ──"
                            NEEDS_BUILD=true
                        elif ! docker manifest inspect ${CI_IMAGE} > /dev/null 2>&1; then
                            echo "── CI image not found in OCIR — building for first time ──"
                            NEEDS_BUILD=true
                        else
                            echo "✓ CI image exists in OCIR — skipping build"
                            docker pull ${CI_IMAGE}
                        fi

                        if [ "$NEEDS_BUILD" = "true" ]; then
                            docker build \
                                -t ${CI_IMAGE} \
                                ci/
                            docker push ${CI_IMAGE}
                            echo "✓ CI image pushed: ${CI_IMAGE}"
                        fi
                    '''
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 1: Checkout
        // Clone source code from GitHub using SSH key
        // ─────────────────────────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                script {
                    def scm = checkout([
                        $class: 'GitSCM',
                        branches: [[name: '*/main']],
                        userRemoteConfigs: [[
                            url: 'git@github.com:mytechbytes/mangocms.git',
                            credentialsId: 'github-ssh-key-mytechbytes'
                        ]]
                    ])
                    // Capture commit metadata from checkout result — no git binary needed
                    env.GIT_COMMIT_SHORT = scm.GIT_COMMIT.take(7)
                    env.GIT_BRANCH_NAME  = scm.GIT_BRANCH.replaceAll('^origin/', '')
                }

                sh '''
                    echo "╔══════════════════════════════════════════════╗"
                    echo "  Job     : ${JOB_NAME}"
                    echo "  Action  : ${PIPELINE_ACTION}"
                    echo "  Build   : #${BUILD_NUMBER} (${BUILD_TAG})"
                    echo "  Commit  : ${GIT_COMMIT_SHORT}"
                    echo "  Branch  : ${GIT_BRANCH_NAME}"
                    echo "╚══════════════════════════════════════════════╝"
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 2: CI Infrastructure
        // Spin up test postgres on isolated Docker network
        // Torn down in post.always regardless of pass/fail
        // ─────────────────────────────────────────────────────────────────────
        stage('CI Infrastructure') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                // ── Step 1: Network ───────────────────────────────────────────
                sh '''
                    echo "── [1/3] Creating CI network ──"
                    docker network create mangocms-ci 2>/dev/null || true
                    echo "── Removing any leftover postgres container ──"
                    docker rm -f mangocms-postgres-ci 2>/dev/null || true
                '''

                // ── Step 2: Start postgres ────────────────────────────────────
                sh '''
                    echo "── [2/3] Starting test database ──"
                    docker run -d \
                        --name mangocms-postgres-ci \
                        --network mangocms-ci \
                        -e POSTGRES_USER=postgres \
                        -e POSTGRES_PASSWORD=postgres \
                        -e POSTGRES_DB=mangocms_test \
                        postgres:16-alpine
                '''

                // ── Step 3: Wait for readiness ────────────────────────────────
                sh '''
                    echo "── [3/3] Waiting for postgres to be ready ──"
                    READY=false
                    for i in $(seq 1 30); do
                        docker exec mangocms-postgres-ci \
                            pg_isready -U postgres > /dev/null 2>&1 \
                            && READY=true \
                            && echo "✓ Postgres ready after ${i}s" \
                            && break
                        sleep 1
                    done
                    [ "$READY" = "true" ] || { echo "✗ Postgres did not start in 30s"; exit 1; }
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 3: Setup
        // Fetch Mix dependencies and prepare test database
        // Runs inside CI Docker container — no Elixir needed on Jenkins agent
        // ─────────────────────────────────────────────────────────────────────
        stage('Setup') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                // ── Step 1: Fetch dependencies ────────────────────────────────
                sh '''
                    echo "── [1/2] Fetching dependencies ──"
                    ${DOCKER_RUN} sh -c "
                        mix deps.get &&
                        echo '✓ Dependencies fetched'
                    "
                '''

                // ── Step 2: Setup test database ───────────────────────────────
                sh '''
                    echo "── [2/2] Setting up test database ──"
                    ${DOCKER_RUN} sh -c "
                        mix ecto.create &&
                        mix ecto.migrate &&
                        echo '✓ Database ready'
                    "
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 4a: Compile
        // Must complete before Credo/Dialyzer — all three share the _build
        // volume, so parallel writes would corrupt beam files.
        // ─────────────────────────────────────────────────────────────────────
        stage('Compile') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Compiling (warnings as errors) ──"
                    ${DOCKER_RUN} sh -c "
                        mix compile --warnings-as-errors &&
                        echo '✓ Compile passed'
                    "
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 4b: Quality Checks (Parallel)
        // Credo and Dialyzer only read compiled artifacts — safe to parallelise
        // ─────────────────────────────────────────────────────────────────────
        stage('Quality Checks') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            parallel {

                stage('Credo') {
                    steps {
                        sh '''
                            echo "── Running Credo strict ──"
                            ${DOCKER_RUN} sh -c "
                                mix credo --strict &&
                                echo '✓ Credo passed'
                            "
                        '''
                    }
                }

                stage('Dialyzer') {
                    steps {
                        sh '''
                            echo "── Running Dialyzer ──"
                            ${DOCKER_RUN} sh -c "
                                mix dialyzer --format short &&
                                echo '✓ Dialyzer passed'
                            "
                        '''
                    }
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 5: Tests & Coverage
        // ExUnit full suite with ExCoveralls JSON output
        // Fails pipeline if coverage drops below COVERAGE_THRESHOLD
        // Archives coverage report as Jenkins artifact
        // ─────────────────────────────────────────────────────────────────────
        stage('Tests & Coverage') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                // ── Step 1: Run ExUnit test suite ─────────────────────────────
                sh '''
                    echo "── [1/2] Running ExUnit with coverage ──"
                    ${DOCKER_RUN} sh -c "
                        mix coveralls.json --exclude wip &&
                        echo '✓ Tests passed'
                    "
                '''

                // ── Step 2: Check coverage threshold ─────────────────────────
                sh '''
                    echo "── [2/2] Checking coverage threshold (${COVERAGE_THRESHOLD}%) ──"
                    docker run --rm \
                        -v ${WORKSPACE}/cover:/cover:ro \
                        -e COVERAGE_THRESHOLD=${COVERAGE_THRESHOLD} \
                        ${CI_IMAGE} python3 -c "
import json, os, sys
with open('/cover/excoveralls.json') as f:
    files = json.load(f)['source_files']
relevant = sum(1 for sf in files for x in sf['coverage'] if x is not None)
covered  = sum(1 for sf in files for x in sf['coverage'] if x is not None and x > 0)
cov = round(100.0 * covered / relevant, 1) if relevant > 0 else 100.0
threshold = float(os.environ['COVERAGE_THRESHOLD'])
print('  Coverage        : {}%'.format(cov))
print('  Required minimum: {}%'.format(int(threshold)))
if cov < threshold:
    print('FAIL: {}% below {}%'.format(cov, int(threshold)))
    sys.exit(1)
print('PASS: {}%'.format(cov))
"
                '''
            }
            post {
                always {
                    // Archive coverage report — viewable in Jenkins UI
                    archiveArtifacts(
                        artifacts: 'cover/**/*',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 6: Build & Push
        // Build ARM64 production image via docker buildx
        // Pushes two tags: build-N (permanent) and latest (floating)
        // Image labels include git commit, branch, build number, date
        // ─────────────────────────────────────────────────────────────────────
        stage('Build & Push') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ocir-credentials',
                        usernameVariable: 'OCIR_USER',
                        passwordVariable: 'OCIR_PASS'
                    )
                ]) {
                    // ── Step 1: Login to OCIR ─────────────────────────────────
                    sh '''
                        echo "── [1/3] Logging in to OCIR ──"
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin
                        echo "✓ Logged in to ${REGISTRY}"
                    '''

                    // ── Step 2: Build & push ARM64 image ─────────────────────
                    sh '''
                        echo "── [2/3] Building ARM64 image ──"
                        docker buildx build \
                            --platform linux/arm64 \
                            --label "git.commit=${GIT_COMMIT_SHORT}" \
                            --label "git.branch=${GIT_BRANCH_NAME}" \
                            --label "build.number=${BUILD_NUMBER}" \
                            --label "build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                            -t ${IMAGE_VERSIONED} \
                            -t ${IMAGE_LATEST} \
                            --push \
                            .
                    '''

                    // ── Step 3: Logout & confirm ──────────────────────────────
                    sh '''
                        echo "── [3/3] Confirming push ──"
                        docker logout ${REGISTRY}
                        echo "✓ Pushed: ${IMAGE_VERSIONED}"
                        echo "✓ Pushed: ${IMAGE_LATEST}"
                    '''
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 7: Deploy
        // Five discrete steps so each appears separately in Jenkins output:
        //   1. Update .env with new image tag
        //   2. Pull new image from OCIR
        //   3. Recreate container (zero-downtime, other services untouched)
        //   4. Run database migrations
        //   5. Verify container is healthy and tail logs
        // ─────────────────────────────────────────────────────────────────────
        stage('Deploy') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'production-server-ssh',
                        keyFileVariable: 'SSH_KEY'
                    ),
                    usernamePassword(
                        credentialsId: 'ocir-credentials',
                        usernameVariable: 'OCIR_USER',
                        passwordVariable: 'OCIR_PASS'
                    )
                ]) {

                    // ── Step 1: Update image tag ──────────────────────────────
                    sh '''
                        echo "── [1/5] Updating image tag ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            cd ${APPS_DIR}
                            echo "  Before:"
                            grep "^${ENV_VAR_NAME}" .env
                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=latest|" .env
                            echo "  After:"
                            grep "^${ENV_VAR_NAME}" .env
ENDSSH
                    '''

                    // ── Step 2: Pull latest image ─────────────────────────────
                    sh '''
                        echo "── [2/5] Pulling latest image ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            cd ${APPS_DIR}
                            echo "${OCIR_PASS}" | docker login ${REGISTRY} \
                                -u "${OCIR_USER}" --password-stdin
                            docker compose pull ${CONTAINER_NAME}
                            docker logout ${REGISTRY}
                            echo "✓ Image pulled"
ENDSSH
                    '''

                    // ── Step 3: Recreate container ────────────────────────────
                    sh '''
                        echo "── [3/5] Recreating container ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            cd ${APPS_DIR}
                            docker compose up -d --no-deps ${CONTAINER_NAME}
                            echo "✓ Container recreated"
ENDSSH
                    '''

                    // ── Step 4: Run migrations ────────────────────────────────
                    sh '''
                        echo "── [4/5] Running migrations ──"
                        echo "── Waiting 15s for container to stabilise ──"
                        sleep 15
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            docker exec ${CONTAINER_NAME} \
                                /app/bin/mangocms eval "MangoCMS.Release.migrate()"
                            echo "✓ Migrations complete"
ENDSSH
                    '''

                    // ── Step 5: Verify deployment ─────────────────────────────
                    sh '''
                        echo "── [5/5] Verifying deployment ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            STATUS=\\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})

                            if [ "\\$STATUS" != "running" ]; then
                                echo "✗ Container not running: \\$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Container status: \\$STATUS"
                            docker logs ${CONTAINER_NAME} --tail 20
                            echo "✓ Deployed ${BUILD_TAG} successfully"
ENDSSH
                    '''
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 8: Smoke Test
        // Hits /health endpoint up to 5 times after deploy
        // Fails pipeline if app not responding — triggers email alert
        // ─────────────────────────────────────────────────────────────────────
        stage('Smoke Test') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Post-deploy smoke test ──"
                    sleep 10

                    for i in 1 2 3 4 5; do
                        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
                            ${APP_URL}/health \
                            --max-time 10 || echo "000")

                        echo "  Attempt ${i}: HTTP ${HTTP_STATUS}"

                        if [ "$HTTP_STATUS" = "200" ]; then
                            echo "✓ Smoke test passed"
                            exit 0
                        fi

                        sleep 5
                    done

                    echo "✗ Smoke test failed after 5 attempts"
                    exit 1
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 9: Rollback
        // Four discrete steps:
        //   1. Validate tag exists in OCIR (local — safe, never touches server)
        //   2. Update .env and pull rollback image on server
        //   3. Recreate container with rollback image
        //   4. Verify container is healthy and tail logs
        // Note: migrations are NOT run on rollback — the old image already
        // ran against the schema it expects.
        // ─────────────────────────────────────────────────────────────────────
        stage('Rollback') {
            when {
                expression { params.PIPELINE_ACTION == 'ROLLBACK' }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'ocir-credentials',
                        usernameVariable: 'OCIR_USER',
                        passwordVariable: 'OCIR_PASS'
                    ),
                    sshUserPrivateKey(
                        credentialsId: 'production-server-ssh',
                        keyFileVariable: 'SSH_KEY'
                    )
                ]) {

                    // ── Step 1: Validate rollback tag in OCIR ─────────────────
                    sh '''
                        echo "── [1/4] Validating rollback tag ──"
                        if [ -z "${ROLLBACK_TAG}" ]; then
                            echo "✗ ROLLBACK_TAG is required"
                            echo "  Example: build-13"
                            exit 1
                        fi

                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin

                        docker manifest inspect \
                            ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:${ROLLBACK_TAG} \
                            > /dev/null 2>&1 || {
                                echo "✗ Tag ${ROLLBACK_TAG} not found in OCIR"
                                exit 1
                            }

                        docker logout ${REGISTRY}
                        echo "✓ Tag ${ROLLBACK_TAG} confirmed in OCIR"
                    '''

                    // ── Step 2: Update .env & pull rollback image ─────────────
                    sh '''
                        echo "── [2/4] Updating .env and pulling rollback image ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            cd ${APPS_DIR}
                            echo "  Before:"
                            grep "^${ENV_VAR_NAME}" .env
                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${ROLLBACK_TAG}|" .env
                            echo "  After:"
                            grep "^${ENV_VAR_NAME}" .env
                            echo "${OCIR_PASS}" | docker login ${REGISTRY} \
                                -u "${OCIR_USER}" --password-stdin
                            docker compose pull ${CONTAINER_NAME}
                            docker logout ${REGISTRY}
                            echo "✓ Pulled ${ROLLBACK_TAG}"
ENDSSH
                    '''

                    // ── Step 3: Recreate container ────────────────────────────
                    sh '''
                        echo "── [3/4] Recreating container ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            set -e
                            cd ${APPS_DIR}
                            docker compose up -d --no-deps ${CONTAINER_NAME}
                            echo "✓ Container recreated"
ENDSSH
                    '''

                    // ── Step 4: Verify rollback ───────────────────────────────
                    sh '''
                        echo "── [4/4] Verifying rollback ──"
                        echo "── Waiting 15s for container to stabilise ──"
                        sleep 15
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH
                            STATUS=\\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})

                            if [ "\\$STATUS" != "running" ]; then
                                echo "✗ Rollback container failed: \\$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Container status: \\$STATUS"
                            docker logs ${CONTAINER_NAME} --tail 20
                            echo "✓ Rollback to ${ROLLBACK_TAG} successful"
ENDSSH
                    '''
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Post Actions
    // Always runs regardless of pipeline result
    // ─────────────────────────────────────────────────────────────────────────
    post {

        success {
            script {
                def action = params.PIPELINE_ACTION
                def body = action == 'BUILD_AND_DEPLOY' ? """
✅ MangoCMS — Build & Deploy Successful

Job       : ${env.JOB_NAME}
Build     : #${env.BUILD_NUMBER} (${env.BUILD_TAG})
Duration  : ${currentBuild.durationString}
App URL   : ${env.APP_URL}
Console   : ${env.BUILD_URL}console
                """ : """
✅ MangoCMS — Rollback Successful

Job       : ${env.JOB_NAME}
Build     : #${env.BUILD_NUMBER}
Rolled to : ${params.ROLLBACK_TAG}
Console   : ${env.BUILD_URL}console
                """

                emailext(
                    subject: "✅ MangoCMS ${action} #${env.BUILD_NUMBER} — SUCCESS",
                    body: body,
                    to: 'mytechbytes.official@gmail.com',
                    mimeType: 'text/plain'
                )
            }
        }

        failure {
            emailext(
                subject: "❌ MangoCMS ${params.PIPELINE_ACTION} #${env.BUILD_NUMBER} — FAILED",
                body: """
❌ MangoCMS — Pipeline Failed

Job     : ${env.JOB_NAME}
Build   : #${env.BUILD_NUMBER}
Action  : ${params.PIPELINE_ACTION}
Console : ${env.BUILD_URL}console

Check console output for details.
                """,
                to: 'mytechbytes.official@gmail.com',
                mimeType: 'text/plain'
            )
        }

        always {
            sh '''
                echo "── Cleaning up CI infrastructure ──"

                # Stop and remove test postgres container
                docker stop mangocms-postgres-ci 2>/dev/null || true
                docker rm   mangocms-postgres-ci 2>/dev/null || true

                # Remove CI Docker network
                docker network rm mangocms-ci 2>/dev/null || true

                # Clean buildx cache — keep last 5GB to preserve layer cache
                docker buildx prune -f --reserved-space 5GB || true

                # Remove coverage artifacts — created by Docker root so requires
                # Docker to delete; fall back to plain rm if container unavailable
                docker run --rm -v ${WORKSPACE}:/workspace ${CI_IMAGE} \
                    sh -c "rm -rf /workspace/cover" 2>/dev/null \
                    || rm -rf cover/ 2>/dev/null || true

                # Logout from registry
                docker logout ${REGISTRY} 2>/dev/null || true
            '''
        }
    }
}
