import type { components } from './schema'

type Schemas = components['schemas']

export type Config = Schemas['Config']
export type Me = Schemas['Me']
export type Anonymous = Schemas['Anonymous']
export type User = Schemas['User']
export type Role = Schemas['Role']
export type Scope = Schemas['Scope']
export type Token = Schemas['Token']
export type TokenCreated = Schemas['TokenCreated']
export type PackageSummary = Schemas['PackageSummary']
export type PackagePage = Schemas['PackagePage']
export type Package = Schemas['Package']
export type Version = Schemas['Version']
export type Dependency = Schemas['Dependency']
export type Stats = Schemas['Stats']
export type AuditEvent = Schemas['AuditEvent']
export type AuditPage = Schemas['AuditPage']
export type Webhook = Schemas['Webhook']
export type WebhookEvent = Schemas['WebhookEvent']
export type WebhookInput = Schemas['WebhookInput']
export type WebhookCreated = Schemas['WebhookCreated']
export type WebhookPage = Schemas['WebhookPage']
export type Delivery = Schemas['Delivery']
export type DeliveryPage = Schemas['DeliveryPage']
export type DeliveryCounts = Schemas['DeliveryCounts']
export type Settings = Schemas['Settings']
export type Overview = Schemas['Overview']
export type ApiErrorBody = Schemas['Error']

export const roles: Role[] = ['admin', 'publisher', 'reader']
export const scopes: Scope[] = ['read', 'publish']
export const webhookEvents: WebhookEvent[] = [
  'package.published',
  'version.retracted',
  'version.unretracted',
  'package.discontinued',
  'package.continued',
  'version.deleted',
  'package.deleted',
]
