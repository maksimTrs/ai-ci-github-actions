# Bug Tracker Pro

A full-stack bug tracking application built with Go (backend) and Next.js (frontend). The application allows users to create, read, update, and delete bug reports, with support for comments and priority levels.

## Features

- Create and manage bug reports
- Add comments to bugs
- Set priority levels and status
- Real-time updates
- Responsive design
- Comprehensive test coverage (unit, API, E2E, and performance tests)

## Prerequisites

Before running the application, ensure you have the following installed:

- [Node.js](https://nodejs.org/) (v20 or later)
- [Go](https://go.dev/) (v1.21 or later)
- [Docker and Docker Compose](https://docs.docker.com/)
- [Git](https://git-scm.com/)

## Quick Start with Docker Compose

The easiest way to run the application is using Docker Compose:

```bash
# Clone the repository
git clone https://github.com/james-willett/bug-tracker.git
cd bug-tracker

# Launch the application
docker compose up --build
```

The application will be available at:
- Frontend: http://localhost:3000
- Backend API: http://localhost:8080

## Manual Setup

### Backend

```bash
cd bugtracker-backend

# Install dependencies
go mod download

# Run the application
go run cmd/bugtracker/main.go
```

The backend API will be available at http://localhost:8080

### Frontend

```bash
cd bugtracker-frontend

# Install dependencies
npm install

# Run the development server
npm run dev
```

The frontend will be available at http://localhost:3000

## Running Tests

The project includes several types of tests:

### Backend Unit Tests
```bash
cd bugtracker-backend
go test ./... -v
```

### Frontend Unit Tests
```bash
cd bugtracker-frontend
npm test
```

### API Tests
```bash
cd tests-api
npm install
npm run test:local
```

### E2E Tests
```bash
cd tests-e2e
npm install
npx playwright test
```

### Performance Tests
First, install K6:
```bash
# MacOS
brew install k6

# Windows
winget install k6

# Linux
For Linux installation instructions, please refer to the [official K6 installation guide](https://k6.io/docs/getting-started/installation#linux)
```

Then run the tests:
```bash
cd tests-perf
k6 run script.js
```

## Project Structure

- `bugtracker-backend/` - Go backend application
- `bugtracker-frontend/` - Next.js frontend application
- `tests-api/` - API tests using Playwright
- `tests-e2e/` - End-to-end tests using Playwright
- `tests-perf/` - Performance tests using K6
- `jenkins/` - Contains Jenkins pipeline configurations

## Jenkins CI/CD

The project includes Jenkins pipelines located in the `jenkins/` folder for continuous integration and deployment.

To start Jenkins locally using Docker Compose:

```bash
cd jenkins
docker-compose up --build
```

Jenkins will then be available at [http://localhost:9000](http://localhost:9000).

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details 
