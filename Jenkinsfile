// NetWatch – CI/CD-Pipeline (Declarative Pipeline)
//
// Ablauf:  Checkout → Lint → Unit-Tests → Image bauen → Integrationstest → Deploy
//
// Schlägt eine Stage fehl, bricht Jenkins die Pipeline sofort ab. "Deploy" wird
// also nur erreicht, wenn ALLE Prüfungen bestanden wurden – eine fehlerhafte
// Version wird nie ausgerollt, die laufende Version bleibt in Betrieb.
//
// Voraussetzungen auf dem Jenkins-Server (siehe docs/vm-setup.md):
//   - Benutzer "jenkins" ist Mitglied der Gruppe "docker"
//   - Jenkins-Credential "netwatch-db" (Typ "Username with password") mit den
//     Zugangsdaten der produktiven Datenbank – steht NICHT in diesem Repository

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    triggers {
        // Jenkins fragt alle 2 Minuten bei GitHub nach neuen Commits (Polling).
        // Begründung und Vergleich mit Webhooks: siehe README.md
        pollSCM('H/2 * * * *')
    }

    environment {
        IMAGE_NAME   = 'netwatch'
        // Jeder Build erzeugt ein eigenes Image netwatch:<Buildnummer>;
        // compose.yaml verwendet genau diesen Tag.
        NETWATCH_TAG = "${env.BUILD_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git log -1 --pretty="Commit %h von %an: %s"'
                // Testberichte des vorherigen Laufs entfernen: der Workspace bleibt
                // zwischen Builds bestehen. Ohne das wertet Jenkins am Ende den alten
                // Bericht erneut aus, wenn die Tests gar nicht erst ausgeführt wurden
                // (z. B. bei einem Abbruch in der Stage Lint).
                sh 'rm -rf test-results'
            }
        }

        stage('Lint') {
            steps {
                // Statische Code-Analyse der Bash-Skripte mit ShellCheck
                sh 'docker run --rm -v "$WORKSPACE:/mnt:ro" -w /mnt koalaman/shellcheck:stable bin/*.sh tests/*.sh'
            }
        }

        stage('Unit-Tests') {
            steps {
                // bats-Tests im Container; Ergebnis zusätzlich als JUnit-XML für Jenkins
                sh '''
                    mkdir -p test-results
                    docker run --rm --user "$(id -u):$(id -g)" \
                        -v "$WORKSPACE:/code:ro" -v "$WORKSPACE/test-results:/reports" \
                        bats/bats:latest --formatter tap --report-formatter junit --output /reports /code/tests
                '''
            }
        }

        stage('Image bauen') {
            steps {
                sh 'docker build --build-arg VERSION="$(git rev-parse --short HEAD)" -t "$IMAGE_NAME:$NETWATCH_TAG" .'
            }
        }

        stage('Integrationstest') {
            environment {
                COMPOSE_PROJECT_NAME = "netwatch-test-${env.BUILD_NUMBER}"
            }
            steps {
                sh 'bash tests/integration.sh'
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'netwatch-db',
                                                  usernameVariable: 'POSTGRES_USER',
                                                  passwordVariable: 'POSTGRES_PASSWORD')]) {
                    sh '''
                        docker compose -p netwatch up -d --no-build --wait
                        docker tag "$IMAGE_NAME:$NETWATCH_TAG" "$IMAGE_NAME:latest"
                        docker compose -p netwatch ps
                    '''
                }
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'test-results/*.xml'
        }
        success {
            echo "NetWatch Build ${env.BUILD_NUMBER} getestet und bereitgestellt."
        }
        failure {
            echo 'Pipeline fehlgeschlagen – es wurde keine neue Version bereitgestellt.'
            // Image der fehlerhaften Version entfernen, falls es schon gebaut wurde
            sh 'docker image rm "$IMAGE_NAME:$NETWATCH_TAG" 2>/dev/null || true'
        }
    }
}
