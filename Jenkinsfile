pipeline {
    agent none

    triggers {
        pollSCM('H/2 * * * *')  // check for new commits every ~2 minutes
    }

    options {
        // abort the entire pipeline if it runs longer than 10 minutes
        timeout(time: 15, unit: 'MINUTES')
        // prefix every log line with the wall-clock time
        timestamps()
        // render ANSI color codes from test runners (Playwright, k6, Go) in Jenkins logs
        ansiColor('xterm')
        // cancel any in-progress build for this branch when a new one starts
        disableConcurrentBuilds(abortPrevious: true)
        // keep only the last 5 builds and their artifacts to save disk space
        buildDiscarder(logRotator(numToKeepStr: '5', artifactNumToKeepStr: '5'))
    }

    stages {
        stage('Unit Tests') {
            failFast false  // both shards run to completion even if one fails — get full results
            parallel {
                stage('Backend') {
                    agent {
                        docker {
                            image 'snakee/golang-junit:1.21'
                            reuseNode true
                            args '-u root'
                        }
                    }
                    steps {
                        dir('bugtracker-backend') {
                            sh '''
                                # -set-exit-code: without this go-junit-report exits 0 even when tests fail
                                # build would stay green
                                go test -v -coverprofile=coverage.out -covermode=atomic ./... 2>&1 \
                                    | go-junit-report -set-exit-code > test-results.xml

                                go tool cover -html=coverage.out -o coverage.html
                                mkdir -p reports
                                mv coverage.html reports/
                            '''
                        }
                    }
                    post {
                        always {
                            junit testResults: 'bugtracker-backend/test-results.xml',
                                  allowEmptyResults: false
                            publishHTML target: [
                                allowMissing:          true,   // coverage.html not written when tests fail — prevents double failure in post
                                alwaysLinkToLastBuild: true,
                                keepAll:               true,
                                reportDir:             'bugtracker-backend/reports',
                                reportFiles:           'coverage.html',
                                reportName:            'Backend Coverage Report'
                            ]
                        }
                    }
                }

                stage('Frontend') {
                    agent {
                        docker {
                            image 'node:20-alpine'
                            reuseNode true  // share workspace with outer agent — no separate checkout inside container
                            // mount host npm cache so npm ci reuses downloaded packages across builds
                            args '-v $HOME/.npm:/root/.npm'
                        }
                    }
                    steps {
                        dir('bugtracker-frontend') {
                            sh '''
                                npm ci
                                npm test
                                rm -rf reports
                                mkdir -p reports
                                mv coverage reports/
                            '''
                        }
                    }
                    post {
                        always {
                            junit testResults: 'bugtracker-frontend/test-results.xml',
                                  allowEmptyResults: false
                            publishHTML target: [
                                allowMissing:          true,   // coverage dir not written when tests fail — prevents double failure in post
                                alwaysLinkToLastBuild: true,
                                keepAll:               true,
                                reportDir:             'bugtracker-frontend/reports/coverage',
                                reportFiles:           'index.html',
                                reportName:            'Frontend Coverage Report'
                            ]
                        }
                    }
                }
            }
        }

        stage('Launch Application') {
            agent {
                docker {
                    image 'docker:27.5.1'
                    reuseNode true
                    // mount host Docker socket (DooD) so compose controls host-level containers
                    args '-v /var/run/docker.sock:/var/run/docker.sock -u 0'
                }
            }
            steps {
                // --wait implies detached mode and blocks until all services are healthy/running
                // --wait-timeout prevents the stage from hanging indefinitely if a service never becomes healthy
                sh 'docker compose up --build --wait --wait-timeout 60'
            }
        }

        stage('API Tests') {
            agent {
                docker {
                    image 'node:20-alpine'
                    reuseNode true
                    // --network=host lets the container reach compose services via localhost ports
                    // no browser install needed — all tests use Playwright request fixture (pure HTTP)
                    args '--network=host -v $HOME/.npm:/root/.npm'
                }
            }
            environment {
                FORCE_COLOR = '1'  // force Playwright list reporter to emit ANSI codes — rendered by AnsiColor plugin
            }
            steps {
                dir('tests-api') {
                    sh 'npm ci'
                    sh 'npx playwright test'
                }
            }
            post {
                always {
                    junit testResults: 'tests-api/test-results/results.xml',
                          allowEmptyResults: false
                    publishHTML target: [
                        allowMissing:          true,
                        alwaysLinkToLastBuild: true,
                        keepAll:               true,
                        reportDir:             'tests-api/playwright-report',
                        reportFiles:           'index.html',
                        reportName:            'API Tests Report'
                    ]
                }
            }
        }

        stage('E2E Tests') {
            agent {
                docker {
                    image 'mcr.microsoft.com/playwright:v1.50.0-jammy'
                    reuseNode true
                    // -u 0: root required for Chromium sandbox and browser deps
                    // --network=host: reaches compose services on localhost ports (same as API Tests)
                    args '-u 0 --network=host -v $HOME/.npm:/root/.npm'
                }
            }
            environment {
                CI          = 'true'  // activates headless mode in playwright.config.ts
                FORCE_COLOR = '1'     // force Playwright list reporter to emit ANSI codes — rendered by AnsiColor plugin
            }
            steps {
                dir('tests-e2e') {
                    sh 'npm ci'
                    sh 'npx playwright test'
                }
            }
            post {
                always {
                    junit testResults: 'tests-e2e/test-results/results.xml',
                          allowEmptyResults: false
                    publishHTML target: [
                        allowMissing:          true,
                        alwaysLinkToLastBuild: true,
                        keepAll:               true,
                        reportDir:             'tests-e2e/playwright-report',
                        reportFiles:           'index.html',
                        reportName:            'Playwright E2E Test Report'
                    ]
                }
            }
        }

        stage('Performance Tests') {
            options {
                // k6 script runs 30s + container startup overhead; 5 min fits within pipeline-level 10 min ceiling
                timeout(time: 5, unit: 'MINUTES')
            }
            agent {
                docker {
                    image 'grafana/k6:2.0.0'
                    reuseNode true
                    // --network=host: k6 needs to reach compose services on localhost ports
                    // --entrypoint="": Jenkins agent requires a shell; k6 image sets its own entrypoint
                    args '--network=host --entrypoint=""'
                }
            }
            steps {
                dir('tests-perf') {
                    // catchError: k6 exits 99 when thresholds are breached — treat as UNSTABLE, not FAILED
                    // threshold breach means SLO violated, not pipeline broken; downstream stages (cleanup) still run
                    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                        sh 'k6 run script.js'
                    }
                }
            }
            post {
                always {
                    // allowMissing: if k6 crashed before handleSummary ran, HTML won't exist — don't mask the real error
                    // keepAll: retain one report per build for cross-run comparison
                    publishHTML target: [
                        allowMissing:          true,
                        alwaysLinkToLastBuild: true,
                        keepAll:               true,
                        reportDir:             'tests-perf',
                        reportFiles:           'perf-results.html',
                        reportName:            'Performance Test Results'
                    ]
                }
            }
        }
    }

    post {
        always {
            // run cleanup inside docker:27.5.1 — Jenkins node has no Compose V2 plugin
            // --rmi local removes compose-built images; prune cleans dangling layers from previous builds
            // --remove-orphans removes containers left over from a previous run whose services no longer exist in compose file
            timeout(time: 5, unit: 'MINUTES') {
                script {
                    docker.image('docker:27.5.1')
                          .inside('-v /var/run/docker.sock:/var/run/docker.sock -u 0') {
                        sh 'docker compose down --volumes --remove-orphans --rmi local && docker image prune -f'
                    }
                }
            }
        }
        failure {
            echo 'Pipeline FAILED — notify team here (Slack/email)'
        }
        regression {
            echo 'Pipeline REGRESSION — was green, now red'
        }
        cleanup {
            node('') {
                cleanWs()
            }
        }
    }
}
