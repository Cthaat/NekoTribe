export interface MailDetailItem {
  label: string;
  value: string;
}

export interface MailPreview {
  title: string;
  text: string;
  to: string | null;
}

export interface MailItem {
  id: string;
  avatar: string;
  name: string;
  email: string;
  subject: string;
  text: string;
  date: string;
  read: boolean;
  labels: string[];
  type: string;
  typeLabel: string;
  priority: string;
  priorityLabel: string;
  href: string | null;
  actorHref: string | null;
  primaryActionLabel: string;
  details: MailDetailItem[];
  primaryPreview: MailPreview | null;
  secondaryPreview: MailPreview | null;
}
