pipeline {
    agent any

    parameters {
        choice(
            name: 'PIPELINE_ACTION',
            choices: ['BUILD_AND_DEPLOY', 'ROLLBACK'],
            description: 'Select action to perform'
        )
        string(
            name: 'ROLLBACK_TAG',
            defaultValue: '',
            description: 'Tag to rollback to e.g. build-13. Required for ROLLBACK only.'
        )
    }

    environment {
        REGISTRY          = 'ap-mumbai-1.ocir.io'
        OCI_NAMESPACE     = 'bmsedjmf13c1'
        IMAGE_NAME        = 'mangocms'
        CONTAINER_NAME    = 'cms'
        ENV_VAR_NAME      = 'CMS_IMAGE_TAG'
        PRODUCTION_HOST   = '161.118.161.178'
        PRODUCTION_USER   = 'ubuntu'
        APPS_DIR          = '/home/ubuntu/apps'
    }

    stages {

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
                        # Login to OCIR
                        echo "$OCIR_PASS" | docker login ${REGISTRY} \
                          -u "$OCIR_USER" --password-stdin

                        # Build ARM64 image and push both tags
                        docker buildx build \
                          --platform linux/arm64 \
                          -t ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:build-${BUILD_NUMBER} \
                          -t ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:latest \
                          --push .

                        docker logout ${REGISTRY}
                    '''
                }
            }
        }

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
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} "
                                cd ${APPS_DIR}

                                # Update image tag to latest
                                sed -i 's|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=latest|' .env

                                # Pull latest and recreate container only
                                docker compose pull ${CONTAINER_NAME}
                                docker compose up -d --no-deps ${CONTAINER_NAME}

                                # Confirm running
                                docker compose ps ${CONTAINER_NAME}
                            "
                    '''
                }
            }
        }

        stage('Rollback') {
            when {
                expression { params.PIPELINE_ACTION == 'ROLLBACK' }
            }
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'production-server-ssh',
                        keyFileVariable: 'SSH_KEY'
                    )
                ]) {
                    sh '''
                        # Validate rollback tag provided
                        if [ -z "${ROLLBACK_TAG}" ]; then
                            echo "ERROR: ROLLBACK_TAG is required"
                            exit 1
                        fi

                        ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=no \
                            ${PRODUCTION_USER}@${PRODUCTION_HOST} "
                                cd ${APPS_DIR}

                                # Validate tag exists before touching .env
                                docker manifest inspect \
                                  ${REGISTRY}/${OCI_NAMESPACE}/${IMAGE_NAME}:${ROLLBACK_TAG} \
                                  > /dev/null 2>&1 || {
                                    echo 'ERROR: Tag ${ROLLBACK_TAG} not found in registry'
                                    exit 1
                                  }

                                # Point to historical tag
                                sed -i 's|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${ROLLBACK_TAG}|' .env

                                # Pull historical image and recreate
                                docker compose pull ${CONTAINER_NAME}
                                docker compose up -d --no-deps ${CONTAINER_NAME}

                                # Confirm running
                                docker compose ps ${CONTAINER_NAME}
                            "
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "SUCCESS — ${params.PIPELINE_ACTION} completed for ${IMAGE_NAME}"
        }
        failure {
            echo "FAILED — ${params.PIPELINE_ACTION} failed for ${IMAGE_NAME}"
        }
    }
}
