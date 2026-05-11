variable "project" {
  description = "Project name used as a prefix on all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "services" {
  description = "List of microservice names — one ECR repository is created per service"
  type        = list(string)
  default = [
    "frontend",
    "cartservice",
    "checkoutservice",
    "paymentservice",
    "currencyservice",
    "productcatalogservice",
    "recommendationservice",
    "shippingservice",
    "emailservice",
    "adservice",
    "loadgenerator",
    "shoppingassistantservice"
  ]
}
