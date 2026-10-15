extension radius

@description('The Radius Environment ID. Injected automatically by the rad CLI.')
param environment string

@description('Web frontend image. CI builds it from ./web and passes the digest reference.')
@metadata({
  radius: {
    build: {
      context: 'web'
    }
  }
})
param webImage string

@description('API image. CI builds it from ./api and passes the digest reference.')
@metadata({
  radius: {
    build: {
      context: 'api'
      dockerfile: 'Dockerfile'
    }
  }
})
param apiImage string

var environmentName = last(split(environment, '/'))

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'cibuild-${environmentName}'
  properties: {
    environment: environment
  }
}

resource web 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'web-${environmentName}'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: webImage
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
  }
}

resource api 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'api-${environmentName}'
  properties: {
    environment: environment
    application: app.id
    containers: {
      api: {
        image: apiImage
        ports: {
          api: {
            containerPort: 8080
          }
        }
      }
    }
  }
}
