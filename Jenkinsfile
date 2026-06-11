pipeline {
    agent any

    parameters {
        choice(
            name: 'PIPELINE_ACTION',
            choices: ['BUILD_AND_DEPLOY', 'ROLLBACK'],
            description: 'BUILD_AND_DEPLOY: test, build, push, deploy. ROLLBACK: revert to a previous build tag.'
        )
        string(
            name: 'ROLLBACK_TAG',
            defaultValue: '',
            description: 'Required for ROLLBACK only. e.g. build-13'
        )
        string(
            name: 'COVERAGE_THRESHOLD',
            defaultValue: '80',
            description: 'Minimum test coverage % required to proceed. Default: 80'
        )
    }

    environment {
        // ── Registry ──────────────────────────────────────────────────────────
        REGISTRY        = 'ap-mumbai-1.ocir.io'
        OCI_NAMESPACE   = 'bmsedjmf13c1'
        IMAGE_NAME      = 'mangocms'
        CONTAINER_NAME  = 'cms'
        ENV_VAR_NAME    = 'CMS_IMAGE_TAG'

        // ── Production Server ─────────────────────────────────────────────────
        PRODUCTION_HOST = '161.118.161.178'
        PRODUCTION_USER = 'ubuntu'
        APPS_DIR        = '/home/ubuntu/apps'

        // ── Auto-computed Tags ────────────────────────────────────────────────
        BUILD_TAG       = "build-${env.BUILD_NUMBER}"
        IMAGE_VERSIONED = "${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:build-${env.BUILD_NUMBER}"
        IMAGE_LATEST    = "${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:latest"

        // ── Elixir ────────────────────────────────────────────────────────────
        MIX_ENV         = 'test'
        HEX_HOME        = "${WORKSPACE}/.hex"
        MIX_HOME        = "${WORKSPACE}/.mix"
    }

    options {
        // Keep last 10 builds only — prevents disk bloat on CI
        buildDiscarder(logRotator(numToKeepStr: '10'))

        // Abort if pipeline runs longer than 30 minutes
        timeout(time: 30, unit: 'MINUTES')

        // Prevent concurrent builds on same job — avoids race conditions
        disableConcurrentBuilds()

        // Add timestamps to all console output
        timestamps()

        // Color ANSI output in Jenkins console
        ansiColor('xterm')
    }

    stages {

        // ── Stage 1: Checkout ─────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: '*/main']],
                    userRemoteConfigs: [[
                        url: 'git@github.com:mytechbytes/mangocms.git',
                        credentialsId: 'github-ssh-key-mytechbytes'
                    ]]
                ])

                sh '''
                    echo "╔══════════════════════════════════════════════╗"
                    echo "  Job        : ${JOB_NAME}"
                    echo "  Action     : ${PIPELINE_ACTION}"
                    echo "  Build No   : ${BUILD_NUMBER}"
                    echo "  Build Tag  : ${BUILD_TAG}"
                    echo "  Commit     : $(git rev-parse --short HEAD)"
                    echo "  Branch     : $(git rev-parse --abbrev-ref HEAD)"
                    echo "  Author     : $(git log -1 --pretty=format:'%an')"
                    echo "  Message    : $(git log -1 --pretty=format:'%s')"
                    echo "╚══════════════════════════════════════════════╝"
                '''
            }
        }

        // ── Stage 2: Setup Dependencies ───────────────────────────────────────
        stage('Setup') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Installing Hex and Rebar ──"
                    mix local.hex --force --if-missing
                    mix local.rebar --force --if-missing

                    echo "── Fetching dependencies ──"
                    mix deps.get
                '''
            }
        }

        // ── Stage 3: Parallel Quality Checks ─────────────────────────────────
        // Compile, Credo, and Dialyzer run in parallel — saves time
        stage('Quality Checks') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            parallel {

                stage('Compile') {
                    steps {
                        sh '''
                            echo "── Compiling (test env) ──"
                            MIX_ENV=test mix compile --warnings-as-errors
                        '''
                    }
                }

                stage('Credo') {
                    steps {
                        sh '''
                            echo "── Running Credo (strict mode) ──"
                            MIX_ENV=test mix credo --strict
                        '''
                    }
                }

                stage('Dialyzer') {
                    steps {
                        sh '''
                            echo "── Running Dialyzer ──"
                            echo "── (PLT build on first run — cached after) ──"
                            MIX_ENV=test mix dialyzer --format short
                        '''
                    }
                }
            }
        }

        // ── Stage 4: Tests + Coverage ─────────────────────────────────────────
        stage('Tests & Coverage') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Running ExUnit with coverage ──"
                    MIX_ENV=test mix coveralls.json \
                        --exclude wip \
                        --trace

                    echo "── Checking coverage threshold ──"
                    COVERAGE=$(cat cover/excoveralls.json \
                        | grep -o '"total":[0-9.]*' \
                        | grep -o '[0-9.]*$')

                    echo "  Coverage        : ${COVERAGE}%"
                    echo "  Required minimum: ${COVERAGE_THRESHOLD}%"

                    # Fail pipeline if below threshold
                    if [ $(echo "$COVERAGE < ${COVERAGE_THRESHOLD}" | bc -l) -eq 1 ]; then
                        echo "✗ COVERAGE BELOW THRESHOLD — pipeline aborted"
                        echo "  Got      : ${COVERAGE}%"
                        echo "  Required : ${COVERAGE_THRESHOLD}%"
                        exit 1
                    fi

                    echo "✓ Coverage check passed: ${COVERAGE}%"
                '''
            }
            post {
                always {
                    // Archive coverage report as Jenkins artifact
                    archiveArtifacts artifacts: 'cover/**/*', allowEmptyArchive: true
                }
            }
        }

        // ── Stage 5: Build & Push ─────────────────────────────────────────────
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
                    sh '''
                        echo "── Logging in to OCIR ──"
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin

                        echo "── Building ARM64 image ──"
                        echo "  Tags:"
                        echo "    ${IMAGE_VERSIONED}"
                        echo "    ${IMAGE_LATEST}"

                        docker buildx build \
                            --platform linux/arm64 \
                            --no-cache \
                            --label "git.commit=$(git rev-parse --short HEAD)" \
                            --label "git.branch=$(git rev-parse --abbrev-ref HEAD)" \
                            --label "build.number=${BUILD_NUMBER}" \
                            --label "build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                            -t ${IMAGE_VERSIONED} \
                            -t ${IMAGE_LATEST} \
                            --push \
                            .

                        echo "── Logout ──"
                        docker logout ${REGISTRY}

                        echo "✓ Image pushed successfully"
                    '''
                }
            }
        }

        // ── Stage 6: Deploy ───────────────────────────────────────────────────
        stage('Deploy') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'production-server-ssh',
                        keyFileVariable: 'SSH_KEY'
                    )
                ]) {
                    sh '''
                        echo "── Deploying ${BUILD_TAG} to production ──"

                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH

                            set -e

                            cd ${APPS_DIR}

                            echo "── Current running image ──"
                            docker compose ps ${CONTAINER_NAME}

                            echo "── Updating .env → ${ENV_VAR_NAME}=latest ──"
                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=latest|" .env

                            echo "── Pulling latest image ──"
                            docker compose pull ${CONTAINER_NAME}

                            echo "── Recreating container (zero-downtime) ──"
                            docker compose up -d --no-deps ${CONTAINER_NAME}

                            echo "── Waiting 15s for container to stabilise ──"
                            sleep 15

                            echo "── Container status ──"
                            docker compose ps ${CONTAINER_NAME}

                            echo "── Health check ──"
                            STATUS=\$(docker inspect --format='{{.State.Status}}' ${CONTAINER_NAME})
                            if [ "\$STATUS" != "running" ]; then
                                echo "✗ Container is not running — status: \$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Container is running"

                            echo "── Recent logs ──"
                            docker logs ${CONTAINER_NAME} --tail 30

ENDSSH
                    '''
                }
            }
        }

        // ── Stage 7: Smoke Test ───────────────────────────────────────────────
        stage('Smoke Test') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Running post-deploy smoke test ──"

                    # Wait for app to be fully ready
                    sleep 10

                    # Hit health endpoint — retry up to 5 times
                    for i in 1 2 3 4 5; do
                        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
                            https://cms.mytechbytes.in/health \
                            --max-time 10 \
                            --retry 0 || echo "000")

                        echo "  Attempt ${i}: HTTP ${HTTP_STATUS}"

                        if [ "$HTTP_STATUS" = "200" ]; then
                            echo "✓ Smoke test passed — app is responding"
                            exit 0
                        fi

                        sleep 5
                    done

                    echo "✗ Smoke test failed — app not responding after 5 attempts"
                    exit 1
                '''
            }
        }

        // ── Stage 8: Rollback ─────────────────────────────────────────────────
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
                    sh '''
                        if [ -z "${ROLLBACK_TAG}" ]; then
                            echo "✗ ERROR: ROLLBACK_TAG is required"
                            echo "  Example: build-13"
                            exit 1
                        fi

                        echo "── Validating tag ${ROLLBACK_TAG} in OCIR ──"
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin

                        docker manifest inspect \
                            ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:${ROLLBACK_TAG} \
                            > /dev/null 2>&1 || {
                                echo "✗ ERROR: Tag ${ROLLBACK_TAG} not found in OCIR"
                                docker logout ${REGISTRY}
                                exit 1
                            }

                        docker logout ${REGISTRY}
                        echo "✓ Tag ${ROLLBACK_TAG} confirmed"

                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH

                            set -e

                            cd ${APPS_DIR}

                            echo "── Current state ──"
                            grep "^${ENV_VAR_NAME}" .env

                            echo "── Rolling back to ${ROLLBACK_TAG} ──"
                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${ROLLBACK_TAG}|" .env

                            echo "── Pulling ${ROLLBACK_TAG} image ──"
                            docker compose pull ${CONTAINER_NAME}

                            echo "── Recreating container with rollback image ──"
                            docker compose up -d --no-deps ${CONTAINER_NAME}

                            echo "── Waiting 15s to stabilise ──"
                            sleep 15

                            echo "── Container status ──"
                            docker compose ps ${CONTAINER_NAME}

                            STATUS=\$(docker inspect --format='{{.State.Status}}' ${CONTAINER_NAME})
                            if [ "\$STATUS" != "running" ]; then
                                echo "✗ Rollback container failed — status: \$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Rollback successful — running ${ROLLBACK_TAG}"
                            docker logs ${CONTAINER_NAME} --tail 20

ENDSSH
                    '''
                }
            }
        }
    }

    // ── Post Actions ──────────────────────────────────────────────────────────
    post {

        success {
            script {
                def message = params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY'
                    ? """✅ *MangoCMS — Build & Deploy Successful*
                        • Job       : ${env.JOB_NAME}
                        • Build     : #${env.BUILD_NUMBER} (${env.BUILD_TAG})
                        • Commit    : ${sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()}
                        • Author    : ${sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()}
                        • Message   : ${sh(script: "git log -1 --pretty=format:'%s'", returnStdout: true).trim()}
                        • URL       : https://cms.mytechbytes.in"""
                    : """✅ *MangoCMS — Rollback Successful*
                        • Job       : ${env.JOB_NAME}
                        • Build     : #${env.BUILD_NUMBER}
                        • Rolled to : ${params.ROLLBACK_TAG}"""

                // Email notification
                emailext(
                    subject: "✅ MangoCMS ${params.PIPELINE_ACTION} #${env.BUILD_NUMBER} — SUCCESS",
                    body: message,
                    to: 'admin@mytechbytes.in',
                    mimeType: 'text/plain'
                )
            }
        }

        failure {
            script {
                def message = """❌ *MangoCMS — Pipeline Failed*
                    • Job       : ${env.JOB_NAME}
                    • Build     : #${env.BUILD_NUMBER}
                    • Action    : ${params.PIPELINE_ACTION}
                    • Stage     : ${env.STAGE_NAME}
                    • Logs      : ${env.BUILD_URL}console"""

                emailext(
                    subject: "❌ MangoCMS ${params.PIPELINE_ACTION} #${env.BUILD_NUMBER} — FAILED",
                    body: message,
                    to: 'admin@mytechbytes.in',
                    mimeType: 'text/plain'
                )
            }
        }

        always {
            script {
                // Clean workspace to prevent disk bloat on Jenkins CI instance
                sh 'docker buildx prune -f --keep-storage 5GB || true'

                // Clean up test artifacts
                sh 'rm -rf cover/ || true'

                // Clean up .mix and .hex caches older than 7 days
                sh 'find ${WORKSPACE}/.mix -mtime +7 -delete 2>/dev/null || true'
                sh 'find ${WORKSPACE}/.hex -mtime +7 -delete 2>/dev/null || true'
            }
        }
    }
}