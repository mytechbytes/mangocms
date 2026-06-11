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
            description: 'Minimum test coverage % required to proceed.'
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

        // ── Elixir Docker Image — matches Dockerfile exactly ──────────────────
        ELIXIR_IMAGE    = 'elixir:1.20.0-otp-29-alpine'

        // ── Docker run flags for Elixir stages ────────────────────────────────
        // Mounts workspace into container so mix can read source files
        // Caches deps and _build across builds for speed
        DOCKER_RUN = """docker run --rm \
            -v ${WORKSPACE}:/app \
            -v mangocms-deps:/app/deps \
            -v mangocms-build:/app/_build \
            -v mangocms-hex:/root/.hex \
            -v mangocms-mix:/root/.mix \
            -w /app \
            -e MIX_ENV=test \
            -e DATABASE_URL=ecto://postgres:postgres@postgres-ci/mangocms_test \
            -e SECRET_KEY_BASE=ci_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxxxxxxxx \
            --network mangocms-ci \
            ${ELIXIR_IMAGE}"""
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
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
                    echo "  Job     : ${JOB_NAME}"
                    echo "  Action  : ${PIPELINE_ACTION}"
                    echo "  Build   : #${BUILD_NUMBER} (${BUILD_TAG})"
                    echo "  Commit  : $(git rev-parse --short HEAD)"
                    echo "  Author  : $(git log -1 --pretty=format:'%an')"
                    echo "  Message : $(git log -1 --pretty=format:'%s')"
                    echo "╚══════════════════════════════════════════════╝"
                '''
            }
        }

        // ── Stage 2: CI Infrastructure ────────────────────────────────────────
        // Spin up postgres for tests — torn down in post
        stage('CI Infrastructure') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Creating CI Docker network ──"
                    docker network create mangocms-ci 2>/dev/null || true

                    echo "── Starting test database ──"
                    docker run -d \
                        --name mangocms-postgres-ci \
                        --network mangocms-ci \
                        -e POSTGRES_USER=postgres \
                        -e POSTGRES_PASSWORD=postgres \
                        -e POSTGRES_DB=mangocms_test \
                        postgres:16-alpine

                    echo "── Waiting for postgres to be ready ──"
                    for i in $(seq 1 30); do
                        docker exec mangocms-postgres-ci \
                            pg_isready -U postgres > /dev/null 2>&1 && \
                            echo "✓ Postgres ready after ${i}s" && break
                        sleep 1
                    done
                '''
            }
        }

        // ── Stage 3: Setup Dependencies ───────────────────────────────────────
        stage('Setup') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Installing Hex + Rebar ──"
                    ${DOCKER_RUN} sh -c "
                        mix local.hex --force --if-missing &&
                        mix local.rebar --force --if-missing &&
                        echo '✓ Hex and Rebar installed'
                    "

                    echo "── Fetching dependencies ──"
                    ${DOCKER_RUN} sh -c "
                        mix deps.get &&
                        echo '✓ Dependencies fetched'
                    "

                    echo "── Setting up test database ──"
                    ${DOCKER_RUN} sh -c "
                        mix ecto.create &&
                        mix ecto.migrate &&
                        echo '✓ Database ready'
                    "
                '''
            }
        }

        // ── Stage 4: Parallel Quality Checks ─────────────────────────────────
        stage('Quality Checks') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            parallel {

                stage('Compile') {
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

        // ── Stage 5: Tests & Coverage ─────────────────────────────────────────
        stage('Tests & Coverage') {
            when {
                expression { params.PIPELINE_ACTION == 'BUILD_AND_DEPLOY' }
            }
            steps {
                sh '''
                    echo "── Running ExUnit with coverage ──"
                    ${DOCKER_RUN} sh -c "
                        mix coveralls.json --exclude wip &&
                        echo '✓ Tests passed'
                    "

                    echo "── Checking coverage threshold ──"
                    COVERAGE=$(cat cover/excoveralls.json \
                        | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['stats']['total_percent'])
" 2>/dev/null || \
                        grep -o '"total_percent":[0-9.]*' cover/excoveralls.json \
                        | grep -o '[0-9.]*$')

                    echo "  Coverage        : ${COVERAGE}%"
                    echo "  Required minimum: ${COVERAGE_THRESHOLD}%"

                    if [ $(echo "$COVERAGE < ${COVERAGE_THRESHOLD}" | bc -l) -eq 1 ]; then
                        echo "✗ Coverage ${COVERAGE}% below threshold ${COVERAGE_THRESHOLD}%"
                        exit 1
                    fi

                    echo "✓ Coverage check passed: ${COVERAGE}%"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'cover/**/*',
                        allowEmptyArchive: true
                }
            }
        }

        // ── Stage 6: Build & Push ─────────────────────────────────────────────
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

                        docker logout ${REGISTRY}
                        echo "✓ Image pushed: ${IMAGE_VERSIONED}"
                    '''
                }
            }
        }

        // ── Stage 7: Deploy ───────────────────────────────────────────────────
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
                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            -o ConnectTimeout=30 \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH

                            set -e
                            cd ${APPS_DIR}

                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=latest|" .env
                            docker compose pull ${CONTAINER_NAME}
                            docker compose up -d --no-deps ${CONTAINER_NAME}

                            sleep 15

                            STATUS=\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})
                            if [ "\$STATUS" != "running" ]; then
                                echo "✗ Container not running: \$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Deployed ${BUILD_TAG} successfully"
                            docker logs ${CONTAINER_NAME} --tail 20

ENDSSH
                    '''
                }
            }
        }

        // ── Stage 8: Smoke Test ───────────────────────────────────────────────
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
                            https://cms.mytechbytes.in/health \
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

        // ── Stage 9: Rollback ─────────────────────────────────────────────────
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
                            echo "✗ ROLLBACK_TAG is required"
                            exit 1
                        fi

                        echo "── Validating tag ${ROLLBACK_TAG} ──"
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                            -u "$OCIR_USER" --password-stdin

                        docker manifest inspect \
                            ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:${ROLLBACK_TAG} \
                            > /dev/null 2>&1 || {
                                echo "✗ Tag ${ROLLBACK_TAG} not found in OCIR"
                                docker logout ${REGISTRY}
                                exit 1
                            }

                        docker logout ${REGISTRY}

                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} bash << ENDSSH

                            set -e
                            cd ${APPS_DIR}

                            sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${ROLLBACK_TAG}|" .env
                            docker compose pull ${CONTAINER_NAME}
                            docker compose up -d --no-deps ${CONTAINER_NAME}

                            sleep 15

                            STATUS=\$(docker inspect \
                                --format='{{.State.Status}}' ${CONTAINER_NAME})
                            if [ "\$STATUS" != "running" ]; then
                                echo "✗ Rollback container failed: \$STATUS"
                                docker logs ${CONTAINER_NAME} --tail 30
                                exit 1
                            fi

                            echo "✓ Rollback to ${ROLLBACK_TAG} successful"
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
                def action = params.PIPELINE_ACTION
                def subject = "✅ MangoCMS ${action} #${env.BUILD_NUMBER} — SUCCESS"
                def body = action == 'BUILD_AND_DEPLOY' ? """
✅ MangoCMS — Build & Deploy Successful

Job       : ${env.JOB_NAME}
Build     : #${env.BUILD_NUMBER} (${env.BUILD_TAG})
Duration  : ${currentBuild.durationString}
URL       : https://cms.mytechbytes.in
Console   : ${env.BUILD_URL}console
                """ : """
✅ MangoCMS — Rollback Successful

Job       : ${env.JOB_NAME}
Build     : #${env.BUILD_NUMBER}
Rolled to : ${params.ROLLBACK_TAG}
Console   : ${env.BUILD_URL}console
                """

                emailext(
                    subject: subject,
                    body: body,
                    to: 'admin@mytechbytes.in',
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
                to: 'admin@mytechbytes.in',
                mimeType: 'text/plain'
            )
        }

        always {
            sh '''
                echo "── Cleaning up CI infrastructure ──"

                # Stop and remove test postgres
                docker stop mangocms-postgres-ci 2>/dev/null || true
                docker rm   mangocms-postgres-ci 2>/dev/null || true

                # Remove CI network
                docker network rm mangocms-ci 2>/dev/null || true

                # Clean buildx cache
                docker buildx prune -f --keep-storage 5GB || true

                # Clean test coverage artifacts
                rm -rf cover/ || true
            '''
        }
    }
}