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
            description: 'Required for ROLLBACK only. e.g. build-13 (main) or stg-13 (develop)'
        )
        string(
            name: 'COVERAGE_THRESHOLD',
            defaultValue: '80',
            description: 'Minimum test coverage % required to proceed.'
        )
        booleanParam(
            name: 'REBUILD_CI_IMAGE',
            defaultValue: false,
            description: 'Force rebuild of mytechbytes-elixir-ci local image. Set true when Elixir/OTP version changes.'
        )
    }

    environment {
        // ── Registry ──────────────────────────────────────────────────────────
        REGISTRY        = 'ap-mumbai-1.ocir.io'
        OCI_NAMESPACE   = 'bmsedjmf13c1'
        IMAGE_NAME      = 'mangocms'
        PRODUCTION_USER = 'ubuntu'

        // ── Shared CI Image ───────────────────────────────────────────────────
        // Shared across all Elixir app pipelines on this Jenkins server
        // Stored in OCIR so it survives Jenkins server rebuilds
        // Only rebuilds when REBUILD_CI_IMAGE=true or image is missing in OCIR
        CI_IMAGE        = 'ap-mumbai-1.ocir.io/bmsedjmf13c1/mytechbytes-elixir-ci:1.20.1-otp-29'

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
        // Keep last 10 builds — prevents disk bloat on Jenkins server
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
        // Stage 0: Configure
        // Set branch-specific environment variables so all later stages are
        // environment-agnostic. main → production, develop → staging.
        // ─────────────────────────────────────────────────────────────────────
        stage('Configure') {
            steps {
                script {
                    switch (env.BRANCH_NAME) {
                        case 'main':
                            env.DEPLOY_ENV       = 'production'
                            env.TARGET_HOST      = '161.118.161.178'
                            env.TARGET_APPS_DIR  = '/home/ubuntu/apps'
                            env.CONTAINER_NAME   = 'cms'
                            env.ENV_VAR_NAME     = 'CMS_IMAGE_TAG'
                            env.APP_URL          = 'https://cms.mytechbytes.in'
                            env.IMAGE_TAG        = "prd-${env.BUILD_NUMBER}"
                            env.IMAGE_LATEST_TAG = 'prd-latest'
                            break
                        case 'develop':
                            env.DEPLOY_ENV       = 'staging'
                            env.TARGET_HOST      = '161.118.161.178'
                            env.TARGET_APPS_DIR  = '/home/ubuntu/apps-stg'
                            env.CONTAINER_NAME   = 'cms-stg'
                            env.ENV_VAR_NAME     = 'CMS_STG_IMAGE_TAG'
                            env.APP_URL          = 'https://stg.cms.mytechbytes.in'
                            env.IMAGE_TAG        = "stg-${env.BUILD_NUMBER}"
                            env.IMAGE_LATEST_TAG = 'stg-latest'
                            break
                        default:
                            env.DEPLOY_ENV       = 'ci-only'
                            env.IMAGE_TAG        = "pr-${env.BUILD_NUMBER}"
                            env.IMAGE_LATEST_TAG = 'pr-latest'
                    }
                    env.IMAGE_VERSIONED = "${env.REGISTRY}/${env.OCI_NAMESPACE}/${env.IMAGE_NAME}:${env.IMAGE_TAG}"
                    env.IMAGE_LATEST    = "${env.REGISTRY}/${env.OCI_NAMESPACE}/${env.IMAGE_NAME}:${env.IMAGE_LATEST_TAG}"
                }

                sh '''
                    echo "╔══════════════════════════════════════════════╗"
                    echo "  Branch  : ${BRANCH_NAME}"
                    echo "  Target  : ${DEPLOY_ENV}"
                    echo "  Action  : ${PIPELINE_ACTION}"
                    echo "  Build   : #${BUILD_NUMBER} (${IMAGE_TAG})"
                    echo "╚══════════════════════════════════════════════╝"
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 1: CI Image
        // Build the shared Elixir CI runner image locally if missing or forced.
        // Stored in Jenkins local Docker cache — not pushed to any registry.
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
                            echo "✓ CI image exists in OCIR — pulling to local cache"
                            docker pull ${CI_IMAGE}
                        fi

                        if [ "$NEEDS_BUILD" = "true" ]; then
                            docker build -t ${CI_IMAGE} ci/
                            docker push ${CI_IMAGE}
                            echo "✓ CI image pushed: ${CI_IMAGE}"
                        fi
                    '''
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 2: Checkout
        // Clone source code — branch is resolved automatically by Multibranch
        // ─────────────────────────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                script {
                    def scm = checkout([
                        $class: 'GitSCM',
                        branches: [[name: "*/${env.BRANCH_NAME}"]],
                        userRemoteConfigs: [[
                            url: 'git@github.com:mytechbytes/mangocms.git',
                            credentialsId: 'github-ssh-key-mytechbytes'
                        ]]
                    ])
                    env.GIT_COMMIT_SHORT = scm.GIT_COMMIT.take(7)
                    env.GIT_BRANCH_NAME  = scm.GIT_BRANCH.replaceAll('^origin/', '')
                }

                sh '''
                    echo "  Commit  : ${GIT_COMMIT_SHORT}"
                    echo "  Image   : ${IMAGE_VERSIONED}"
                '''
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 3: CI Infrastructure
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
        // Stage 4: Setup
        // Fetch Mix dependencies and prepare test database
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
        // Stage 5: Compile
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
        // Stage 6: Quality Checks (Parallel)
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
        // Stage 7: Tests & Coverage
        // ExUnit full suite with ExCoveralls JSON output
        // Fails pipeline if coverage drops below COVERAGE_THRESHOLD
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
                    archiveArtifacts(
                        artifacts: 'cover/**/*',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 8: Build & Push
        // Build ARM64 production image via docker buildx
        // Pushes versioned tag (build-N / stg-N) and floating tag (latest / stg-latest)
        // Skipped for branches other than main and develop
        // ─────────────────────────────────────────────────────────────────────
        stage('Build & Push') {
            when {
                allOf {
                    expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
                    anyOf { branch 'main'; branch 'develop' }
                }
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
                        echo "── [2/3] Building ARM64 image (${DEPLOY_ENV}) ──"
                        docker buildx build \
                            --platform linux/arm64 \
                            --label "git.commit=${GIT_COMMIT_SHORT}" \
                            --label "git.branch=${GIT_BRANCH_NAME}" \
                            --label "build.number=${BUILD_NUMBER}" \
                            --label "build.env=${DEPLOY_ENV}" \
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
        // Stage 9: Approval (production only)
        // CI runs automatically on main. Deployment waits for a human to
        // approve in the Jenkins UI — develop deploys automatically.
        // ─────────────────────────────────────────────────────────────────────
        stage('Approval') {
            when {
                allOf {
                    expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
                    branch 'main'
                }
            }
            steps {
                timeout(time: 24, unit: 'HOURS') {
                    input(
                        message: "Deploy ${IMAGE_TAG} to production?",
                        ok: 'Deploy to Production'
                    )
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 10: Deploy
        // Five discrete steps:
        //   1. Update .env with new image tag
        //   2. Pull new image from OCIR
        //   3. Recreate container (zero-downtime, other services untouched)
        //   4. Run database migrations
        //   5. Verify container is healthy and tail logs
        // Skipped for branches other than main and develop
        // ─────────────────────────────────────────────────────────────────────
        stage('Deploy') {
            when {
                allOf {
                    expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
                    anyOf { branch 'main'; branch 'develop' }
                }
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
                        echo "── [1/5] Updating image tag on ${DEPLOY_ENV} ──"
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            set -e
                            cd ${TARGET_APPS_DIR}
                            echo "  Before:"
                            grep "^${ENV_VAR_NAME}" .env
                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${IMAGE_LATEST_TAG}|" .env
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            set -e
                            cd ${TARGET_APPS_DIR}
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            set -e
                            cd ${TARGET_APPS_DIR}
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            STATUS=\\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})

                            if [ "\\$STATUS" != "running" ]; then
                                echo "✗ Container not running: \\$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Container status: \\$STATUS"
                            docker logs ${CONTAINER_NAME} --tail 20
                            echo "✓ Deployed ${IMAGE_TAG} to ${DEPLOY_ENV}"
ENDSSH
                    '''
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Stage 11: Smoke Test
        // Hits /health endpoint up to 5 times after deploy
        // ─────────────────────────────────────────────────────────────────────
        stage('Smoke Test') {
            when {
                allOf {
                    expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
                    anyOf { branch 'main'; branch 'develop' }
                }
            }
            steps {
                sh '''
                    echo "── Post-deploy smoke test (${DEPLOY_ENV}) ──"
                    sleep 10

                    for i in 1 2 3 4 5; do
                        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
                            ${APP_URL}/health \
                            --max-time 10 || echo "000")

                        echo "  Attempt ${i}: HTTP ${HTTP_STATUS}"

                        if [ "$HTTP_STATUS" = "200" ]; then
                            echo "✓ Smoke test passed — ${APP_URL}"
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
        // Stage 12: Rollback
        // Only available on main and develop branches
        // Note: migrations are NOT run on rollback
        // ─────────────────────────────────────────────────────────────────────
        stage('Rollback') {
            when {
                allOf {
                    expression { params.PIPELINE_ACTION == 'ROLLBACK' }
                    anyOf { branch 'main'; branch 'develop' }
                }
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
                            echo "  main branch    : build-13"
                            echo "  develop branch : stg-13"
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            set -e
                            cd ${TARGET_APPS_DIR}
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            set -e
                            cd ${TARGET_APPS_DIR}
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
                            ${PRODUCTION_USER}@${TARGET_HOST} bash << ENDSSH
                            STATUS=\\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})

                            if [ "\\$STATUS" != "running" ]; then
                                echo "✗ Rollback container failed: \\$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Container status: \\$STATUS"
                            docker logs ${CONTAINER_NAME} --tail 20
                            echo "✓ Rollback to ${ROLLBACK_TAG} on ${DEPLOY_ENV} successful"
ENDSSH
                    '''
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Post Actions
    // ─────────────────────────────────────────────────────────────────────────
    post {

        success {
            script {
                def action = params.PIPELINE_ACTION
                def env_label = env.DEPLOY_ENV ?: env.BRANCH_NAME
                def body = action == 'BUILD_AND_DEPLOY' ? """
✅ MangoCMS — Build & Deploy Successful

Job       : ${env.JOB_NAME}
Branch    : ${env.BRANCH_NAME}
Env       : ${env_label}
Build     : #${env.BUILD_NUMBER} (${env.IMAGE_TAG})
Duration  : ${currentBuild.durationString}
App URL   : ${env.APP_URL}
Console   : ${env.BUILD_URL}console
                """ : """
✅ MangoCMS — Rollback Successful

Job       : ${env.JOB_NAME}
Branch    : ${env.BRANCH_NAME}
Env       : ${env_label}
Build     : #${env.BUILD_NUMBER}
Rolled to : ${params.ROLLBACK_TAG}
Console   : ${env.BUILD_URL}console
                """

                emailext(
                    subject: "✅ MangoCMS [${env_label}] ${action} #${env.BUILD_NUMBER} — SUCCESS",
                    body: body,
                    to: 'mytechbytes.official@gmail.com',
                    mimeType: 'text/plain'
                )
            }
        }

        failure {
            script {
                def env_label = env.DEPLOY_ENV ?: env.BRANCH_NAME
                emailext(
                    subject: "❌ MangoCMS [${env_label}] ${params.PIPELINE_ACTION} #${env.BUILD_NUMBER} — FAILED",
                    body: """
❌ MangoCMS — Pipeline Failed

Job     : ${env.JOB_NAME}
Branch  : ${env.BRANCH_NAME}
Env     : ${env_label}
Build   : #${env.BUILD_NUMBER}
Action  : ${params.PIPELINE_ACTION}
Console : ${env.BUILD_URL}console

Check console output for details.
                    """,
                    to: 'mytechbytes.official@gmail.com',
                    mimeType: 'text/plain'
                )
            }
        }

        always {
            sh '''
                echo "── Cleaning up CI infrastructure ──"

                docker stop mangocms-postgres-ci 2>/dev/null || true
                docker rm   mangocms-postgres-ci 2>/dev/null || true
                docker network rm mangocms-ci 2>/dev/null || true
                docker buildx prune -f --reserved-space 5GB || true

                docker run --rm -v ${WORKSPACE}:/workspace ${CI_IMAGE} \
                    sh -c "rm -rf /workspace/cover" 2>/dev/null \
                    || rm -rf cover/ 2>/dev/null || true

                docker logout ${REGISTRY} 2>/dev/null || true
            '''
        }
    }
}
