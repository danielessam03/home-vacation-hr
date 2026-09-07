-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_020.sql
-- Contract templates: the real offer / job-description / promotion
-- letters, stored per job role with {{placeholders}} that HR fills from
-- the employee record in one click (Jobs -> role -> Templates).
--   * job_templates              -- body_md with placeholders
--   * job_documents.employee_id  -- a generated document knows its employee
--   * sales team handles rentals AND sales: "rental" metric on the sales
--     board next to "Sale closed"
--   * company / head-office address from the letterhead
-- Seeds the three templates extracted from the CEO's documents
-- (Junior & Senior Sales Consultant offers, Sales Team Leader promotion)
-- plus a job description for each, in English.
-- ADDITIVE ONLY. Run once, after 019.
-- =====================================================================

create table if not exists public.job_templates (
  id          uuid primary key default gen_random_uuid(),
  role_id     uuid references public.job_roles(id) on delete cascade,
  doc_kind    text not null default 'offer' check (doc_kind in ('offer','jd','promotion','contract')),
  language    text not null default 'en' check (language in ('en','ar')),
  title       text not null,
  body_md     text not null,
  is_active   boolean not null default true,
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_job_templates_role on public.job_templates(role_id);
drop trigger if exists trg_job_templates_touch on public.job_templates;
create trigger trg_job_templates_touch before update on public.job_templates
  for each row execute function public.touch_updated_at();
alter table public.job_templates enable row level security;
drop policy if exists job_templates_all on public.job_templates;
create policy job_templates_all on public.job_templates for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

alter table public.job_documents add column if not exists employee_id uuid references public.employees(id);
alter table public.job_documents add column if not exists template_id uuid references public.job_templates(id) on delete set null;
alter table public.job_documents add column if not exists title text;
alter table public.job_documents drop constraint if exists job_documents_doc_kind_check;
alter table public.job_documents add constraint job_documents_doc_kind_check
  check (doc_kind in ('jd','offer','promotion','contract'));

-- sales team closes rentals as well as sales
insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort, category)
values ('rental', 'Rental deal closed', 'صفقة إيجار مغلقة', 20, 5, true, 5, 'sales')
on conflict (code) do nothing;
update public.kpi_metrics set name_en = 'Sale closed', name_ar = 'صفقة بيع مغلقة' where code = 'closing' and name_en = 'Deal closed';

-- letterhead address
update public.app_settings
   set value = value || jsonb_build_object('address', '9 Al-Kawthar Al-Jadid Street, Office 202, Hurghada, Red Sea, Egypt',
                                           'name_en', 'Home Vacation for Real Estate Investment')
 where key = 'company' and coalesce(value->>'address', '') = '';
update public.branches set address = '9 Al-Kawthar Al-Jadid Street, Office 202, Hurghada, Red Sea, Egypt'
 where code = 'HRG-HO' and (address is null or address = 'Hurghada, Red Sea');

-- role titles as they appear in the contracts
update public.job_roles set title_en = 'Junior Sales Consultant', title_ar = 'مستشار مبيعات - مبتدئ' where title_en = 'Junior Sales Representative';
update public.job_roles set title_en = 'Senior Sales Consultant', title_ar = 'مستشار مبيعات - أول'    where title_en = 'Senior Sales Representative';

-- =====================================================================
-- Templates. Placeholders (filled from the employee record):
--   {{employee_name}} {{employee_name_ar}} {{employee_code}} {{national_id}}
--   {{phone}} {{address}} {{position}} {{department}} {{reports_to}}
--   {{direct_reports}} {{location}} {{employment_type}} {{contract_type}}
--   {{probation}} {{start_date}} {{hire_date}} {{effective_date}}
--   {{basic_salary}} {{work_days}} {{work_hours}} {{weekend}} {{today}}
--   {{company_name}} {{company_address}}
-- =====================================================================
do $seed$
declare
  r_junior uuid; r_senior uuid; r_lead uuid;
  hdr text; sales_terms text; ownership text; closing text;
begin
  select id into r_junior from public.job_roles where title_en = 'Junior Sales Consultant' limit 1;
  select id into r_senior from public.job_roles where title_en = 'Senior Sales Consultant' limit 1;
  select id into r_lead   from public.job_roles where title_en = 'Sales Team Leader' limit 1;

  hdr := $t$**{{company_name}}**
{{company_address}}

| | |
|---|---|
| **Position** | {{position}} |
| **Department** | {{department}} |
| **Reports to** | {{reports_to}} |
| **Location** | {{location}} |
| **Employment type** | {{employment_type}} |
| **Contract type** | {{contract_type}} |
| **Probation period** | {{probation}} |
| **Start date** | {{start_date}} |
$t$;

  ownership := $t$## 4. Lead & Listing Ownership

**4.1 The CRM is the sole record of ownership.** A lead or unit belongs to the Consultant registered against it in the Company CRM, and to no one else. The CRM registration date and time is the only evidence accepted in any dispute. Verbal claims, messages, business cards, personal notes and prior acquaintance with a client create no entitlement.

**4.2 Walk-in and Company-generated clients.** Clients who walk into the office, or who arrive through the Company's marketing, advertising, portals, website or social media, are Company clients, assigned to a Consultant by the Marketing Department. A Consultant who happens to meet, greet or speak with such a client, by chance, by being in the office, or by covering for a colleague, acquires no ownership of that client and no entitlement to the lead commission under Section 3.5. The commission follows the assignment, not the encounter.

**4.3 Registering a lead.** Before working a lead, the Consultant must submit it to Marketing to be checked against the CRM. If the lead is already registered, to the Company or another Consultant, no lead entitlement arises, regardless of who spoke to the client first. If it is not registered, Marketing registers it in the Consultant's name and the timestamp establishes ownership. A lead that is not in the CRM does not exist.

**4.4 Registering a unit (sale or rental).** Before presenting or marketing any unit, the Consultant must submit it to Marketing to be checked against the CRM. If the unit is already registered by a colleague or the Company, no sourcing entitlement arises, even where the Consultant has a relationship with the owner. If it is not registered, Marketing registers it in the Consultant's name and the timestamp establishes ownership. First to register prevails, not first to be told, not first to visit.

**4.5 Conflicting claims.** Where two Consultants claim the same client or unit, the earlier CRM timestamp prevails without exception. Where a client independently contacts more than one Consultant, the client remains with the earlier registration.

**4.6 Bypassing registration.** Working a client or marketing a unit outside the CRM, to protect a claim, avoid a colleague, or for any reason, is a breach of this agreement. No commission entitlement arises from it, and the matter is handled under the Company's approved internal penalties regulation.

**4.7 Lead expiry.** A registered lead reverts to the Company after [ 90 / 120 – confirm ] days without logged activity, or [ 6 – confirm ] months without a closed deal, after which it may be reassigned.

## 5. On Departure

On the Consultant's last working day, all leads, listings and client relationships revert to the Company. The Consultant has no claim to commission on deals closed after departure, except deals already contracted and awaiting collection, on which commission is paid when the funds are received.

## 6. Confidentiality & Company Property

Client and owner data, pricing structures, developer terms and the Company database are the exclusive property of {{company_name}} and may not be copied, shared or used outside the Company. This obligation continues after employment ends, limited to [ duration / scope – confirm for enforceability ].

## 7. Working Hours

{{work_days}} days per week, {{work_hours}}. Rest day(s): {{weekend}}. Where a client viewing falls on the Consultant's rest day, an alternative rest day is granted within the following week in accordance with Egyptian labour law.

## 8. Acceptance

I have read and understood this offer, including the compensation and ownership terms in Sections 3 and 4, and I accept them.

**The Consultant**

Name: {{employee_name}}    Signature: ______________________    Date: ______________

**For the Company**

Name: ______________________    Signature: ______________________    Date: ______________
$t$;

  sales_terms := $t$**3.2 Fuel & Inspection Expenses**

The Company covers the fuel cost of property inspections conducted with clients, provided each trip is recorded in the inspection log approved by the Sales Team Leader. Trips not recorded in the log are not reimbursed.

Reimbursement is proportionate to sales results, as follows:

- Below 50% of the monthly target: reimbursement is capped at EGP 500 per month, and any further inspections are at the Consultant's own cost.
- At 50% of the target or above: reimbursement is capped at a monthly ceiling linked to performance, per the following tiers:

| Monthly target achievement | Monthly fuel ceiling |
|---|---|
| 50% – 80% | EGP 800 |
| Above 80% – 100% | EGP 1,000 |
| Above 100% | EGP 1,500 |

These ceilings are set by Management and may be revised in writing according to market conditions. Each inspection is assessed on its seriousness; repeated inspections for a client not registered as a "serious buyer" in the CRM are not reimbursed.

**3.3 Monthly Sales Target**

The monthly sales target for each Consultant is set by Management before the start of each month and communicated to the Consultant in writing before the month begins, ensuring transparency and clarity.

The target shall be reasonable and proportionate to the Consultant's experience and job level, and may therefore differ from one Consultant to another. The target may not be amended retroactively once the month has started.

Target achievement is calculated upon signature of the contract within the month. However, commission is neither due nor paid until the Company has actually received the transaction value and its commission, and is paid in the month following the month of collection.
$t$;

  closing := $t$**3.5 Commission on Contribution**

Where the Consultant contributes to, rather than solely closes, a transaction, the following fixed rates apply regardless of monthly target achievement:

| Contribution | Share of net commission |
|---|---|
| Introducing a qualified lead ("serious buyer") that results in a closed deal | 15% |
| Sourcing a unit for sale or rent that results in a closed deal | 10% |

A "serious buyer" is a client registered in the CRM with [ full name, verified phone, nationality, confirmed budget, project of interest, source – confirm fields ] who has [ attended an inspection / confirmed intent – confirm threshold ].

**3.6 Deals Involving an External Broker**

- Resale: the external broker receives up to 50% of the total commission. The Consultant receives 5% as the introducing-broker share, plus the closing commission under 3.4 on the remaining amount.
- Primary (off-plan): the external broker receives up to 30% from the Company. The Consultant receives 5% as the broker share, plus the closing commission on the remaining amount, capped at 15%.

**3.7 Definition of Net Commission**

"Net commission" is the commission the Company actually receives from the client, developer or owner, after deducting VAT and applicable taxes, bank and transfer charges, portal or platform fees attributable to the transaction, and any commission share payable to an external broker or referral party. [ Confirm this list. ]

All commission percentages are calculated as a share of the Company's net commission on the transaction, in the same currency as that transaction, whatever it may be. Targets and commissions are not tied to any particular currency.

**3.8 Payment Terms**

- Commission is earned only on amounts actually collected and retained by the Company, not on signature. No entitlement arises on any amount the Company has not received.
- Commission is paid on the 15th of the month following the month of collection.
- Where a transaction is subsequently cancelled, rescinded or refunded, the entitlement does not arise; any amount already advanced against it is offset against future commission entitlements.
$t$;

  /* ---------------- Junior Sales Consultant: offer ---------------- */
  if r_junior is not null and not exists (select 1 from public.job_templates where title = 'Employment Offer – Junior Sales Consultant') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_junior, 'offer', 'en', 'Employment Offer – Junior Sales Consultant',
'# EMPLOYMENT OFFER – Sales Consultant (Junior)

' || hdr || $t$
## 1. Role Purpose

To generate, qualify and convert buyer and tenant enquiries into completed transactions across Home Vacation's off-plan, resale and rental portfolio, and to grow the Company's inventory by sourcing new units for sale and rent, while maintaining accurate records in the Company CRM at every stage.

## 2. Key Responsibilities

**Sales & Conversion**

- Respond to all assigned leads within the Company's stated response time and log every client contact in the CRM the same day.
- Conduct property inspections and site visits with clients.
- Present projects, payment plans and contract terms accurately, using only Company-approved materials and pricing.
- Negotiate and close transactions and hand complete, signed documentation to Administration.

**Inventory & Lead Generation**

- Source new units (sale and rental) from owners and developers and register them with the Company.
- Generate leads through referrals, networking and follow-up on the existing database.

**Reporting & Compliance**

- Submit the daily activity report and weekly pipeline update. Any activity not recorded in writing is treated as not having taken place.
- Give no pricing, discount, payment-plan or delivery commitment to any client without the prior written approval of the Sales Team Leader.

## 3. Compensation

**3.1 Basic Salary**

{{basic_salary}} gross per month, within the Company's Junior Sales Consultant band of EGP 8,000 – 10,000, or the statutory minimum wage in force at the time of payment, whichever is higher. Salary is paid at the beginning of each month and is subject to income tax, social insurance and any other statutory deductions under Egyptian law. The Consultant is entitled to the statutory annual periodic increment required by law.

$t$ || sales_terms || $t$
**3.4 Commission on Deals Closed by the Consultant Alone**

Commission is a percentage of the net commission actually collected and retained by the Company on the Consultant's deals, set by the target-achievement level reached in the month the deal is signed:

| Monthly target achievement | Consultant's share of net commission |
|---|---|
| From first sale – 80% | 15% |
| Above 80% – 100% | 17% |
| Above 100% | 20% |

The rate reached at month-end applies to all deals the Consultant signed in that month, not only the portion above the threshold.

$t$ || closing || $t$
$t$ || ownership);
  end if;

  /* ---------------- Senior Sales Consultant: offer ---------------- */
  if r_senior is not null and not exists (select 1 from public.job_templates where title = 'Employment Offer – Senior Sales Consultant') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_senior, 'offer', 'en', 'Employment Offer – Senior Sales Consultant',
'# EMPLOYMENT OFFER – Sales Consultant (Senior)

' || hdr || $t$
## 1. Role Purpose

To independently generate, qualify and close buyer and tenant transactions across Home Vacation's off-plan, resale and rental portfolio, and to grow the Company's inventory by sourcing new units for sale and rent. As an experienced consultant, the Senior Sales Consultant manages the full sales cycle without support, sets a professional example for junior colleagues, and maintains accurate records in the Company CRM at every stage.

## 2. Key Responsibilities

**Sales & Conversion**

- Independently manage the full sales cycle, from first contact to signed contract and handover, without requiring closing support.
- Respond to all assigned leads within the Company's stated response time and log every client contact in the CRM the same day.
- Conduct property inspections and site visits with clients.
- Present projects, payment plans and contract terms accurately, using only Company-approved materials and pricing.
- Negotiate and close transactions and hand complete, signed documentation to Administration.

**Inventory & Lead Generation**

- Source new units (sale and rental) from owners and developers and register them with the Company.
- Generate leads through referrals, networking, farming and follow-up on the existing database.

**Experience & Standards**

- Apply established market knowledge and negotiation experience to close deals efficiently and protect the Company's margins.
- Support and set an example for junior colleagues where requested by the Sales Team Leader.

**Reporting & Compliance**

- Submit the daily activity report and weekly pipeline update. Any activity not recorded in writing is treated as not having taken place.
- Give no pricing, discount, payment-plan or delivery commitment to any client without the prior written approval of the Sales Team Leader.

## 3. Compensation

**3.1 Basic Salary**

{{basic_salary}} gross per month, within the Company's Senior Sales Consultant band of EGP 11,000 – 15,000, set according to the Consultant's experience, or the statutory minimum wage in force at the time of payment, whichever is higher. Salary is paid at the beginning of each month and is subject to income tax, social insurance and any other statutory deductions under Egyptian law. The Consultant is entitled to the statutory annual periodic increment required by law.

$t$ || sales_terms || $t$
**3.4 Commission on Deals Closed by the Consultant**

As an experienced consultant who closes independently, the Senior Sales Consultant earns commission as a percentage of the net commission actually collected and retained by the Company on the Consultant's deals, set by the target-achievement level reached in the month the deal is signed:

| Monthly target achievement | Consultant's share of net commission |
|---|---|
| 0% – 80% | 17% |
| Above 80% – 100% | 20% |
| Above 100% | 25% |

The rate reached at month-end applies to all deals the Consultant signed in that month, not only the portion above the threshold.

$t$ || closing || $t$
$t$ || ownership);
  end if;

  /* ---------------- Sales Team Leader: promotion letter ---------------- */
  if r_lead is not null and not exists (select 1 from public.job_templates where title = 'Promotion & Amended Terms – Sales Team Leader') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_lead, 'promotion', 'en', 'Promotion & Amended Terms – Sales Team Leader',
$t$# PROMOTION & AMENDED TERMS OF EMPLOYMENT – Sales Team Leader

**{{company_name}}**
{{company_address}}

| | |
|---|---|
| **Employee** | {{employee_name}} |
| **New position** | {{position}} |
| **Department** | {{department}} |
| **Reports to** | {{reports_to}} |
| **Direct reports** | {{direct_reports}} |
| **Location** | {{location}} |
| **Original date of hire** | {{hire_date}} (continuous service preserved) |
| **Effective date of promotion** | {{effective_date}} |
| **Employment type** | {{employment_type}} |
| **Probation period** | None – continuous service preserved |

**Continuity of Service.** This letter amends and supplements the Employee's existing contract of employment. It does not terminate or replace it. The Employee's continuous service is calculated from the original date of hire stated above for all purposes, including end-of-service entitlements, annual leave accrual and notice periods. All terms of the existing contract not expressly amended by this letter remain in full force.

## 1. Role Purpose

To own the Sales Department's monthly result, converting the Company's leads and inventory into completed, collected transactions through a team of Sales Consultants, while personally carrying a sales target as a producing member of that team, and reporting on both in writing every week and every month.

## 2. Key Responsibilities

**Team result ownership**

- Deliver the monthly team sales target set by management in writing before the start of each month.
- Allocate the team target across individual consultants and communicate each consultant's individual target to them in writing before the month begins.
- Intervene on any consultant tracking below 50% of their individual target by mid-month, in writing, with a documented corrective plan.

**Personal production**

- Achieve the Team Leader's own monthly personal sales target, set in writing by management before the start of each month as a defined number of transactions.
- Maintain the same CRM, reporting and approval discipline required of every Sales Consultant.

**Lead distribution & pipeline control**

- Distribute assigned leads among consultants and register every allocation in the Company CRM at the time it is made.
- Review the full team pipeline at least twice weekly and ensure no assigned lead sits without a logged contact beyond the Company's stated response time.
- Enforce CRM discipline across the team. Any team activity not recorded in the CRM is treated as not having taken place, and the Team Leader is accountable for the completeness of the team's records.

**Reporting (mandatory)**

- Weekly report, submitted every [ Saturday ] before [ 12:00 ], covering: leads received and distributed, contacts made, inspections conducted, offers issued, contracts signed, collections received, and each consultant's progress against individual target.
- Monthly report, submitted no later than the 3rd working day of the following month, covering: team achievement against target, per-consultant achievement, the Team Leader's own personal achievement, closed transactions with collection status, lost deals with reasons, inventory added, and the plan for the coming month.
- Reports are submitted in the Company's approved format. A report not submitted by its stated deadline is treated as not submitted.

**Approval & control**

- No pricing, discount, payment plan or delivery commitment may be given to any client by the Team Leader or any team member, outside the approved price list, without the prior written approval of [ management level – to confirm ].
- Approve consultant fuel and inspection logs before submission to Accounts.
- Ensure walk-in clients are handled in accordance with Company policy: walk-in clients belong to the Company and are distributed by the Marketing Department only.

**Team development**

- Onboard new consultants and confirm their competence on the Company's portfolio, payment plans and CRM before they handle clients independently.
- Conduct a documented one-to-one performance review with each consultant at least monthly.

## 3. Compensation

**3.1 Basic Salary**

{{basic_salary}} gross per month, inclusive of social insurance, or the statutory minimum wage in force at the time of payment, whichever is higher. The stated figure is gross and is subject to income tax, the employee's social insurance share and any other statutory deductions under Egyptian law. Salary is paid at the beginning of each month. The Employee remains entitled to the statutory annual periodic increment required by law.

**3.2 Monthly Targets**

Before the start of each month, management sets and confirms in writing:

- (a) The Team Leader's personal target: a defined number of transactions to be closed personally.
- (b) Each consultant's individual target.
- (c) The team target, being the sum of all individual consultant targets plus the Team Leader's personal target.

No fixed target figure forms part of these terms. Targets may differ from month to month according to inventory, project launches and team size. Achievement is measured on the basis of contracts signed within the month.

**3.3 Personal Sales Commission**

On transactions closed personally, the Team Leader earns commission on the Company's net commission at the following rates, determined by personal target achievement:

| Personal target achievement | Share of net commission |
|---|---|
| First sale – 80% | 15% |
| Above 80% – 100% | 20% |
| Above 100% | 25% |

**3.4 Team Override Commission**

Separately, the Team Leader earns an override commission on every sale and rental transaction completed by the team, calculated as a percentage of the net commission earned by the Company on that transaction. The applicable rate is determined at month end by the team's total achievement against the monthly team target:

| Team achievement of monthly target | Override rate |
|---|---|
| Below 30% | Nil |
| 30% up to below 70% | 2% |
| 70% up to below 100% | 3.5% |
| 100% and above | 5% |

Where team achievement falls below 30% of the monthly team target, no override commission is earned for that month. The rate reached at month end applies to all team transactions completed in that month, and not only to those above the relevant bracket threshold.

The Team Leader's own transactions count in both calculations. A transaction closed personally earns personal commission under clause 3.3 and also counts toward the team total for the purposes of clause 3.4, on which the override commission is likewise payable. [ Alternative to confirm: personal transactions count toward team achievement but are excluded from the override commission base. ]

All commission percentages are currency-agnostic and apply to the Company's net commission in whatever currency the transaction is concluded.

**3.5 Origin of the Team Leader's Personal Transactions**

To protect the integrity of lead distribution, transactions counting toward the Team Leader's personal target and personal commission must originate from: (a) self-sourced leads; (b) referrals made to the Team Leader personally; or (c) leads formally released back to the distribution pool by a consultant and re-registered in the CRM. Leads from the incoming distribution pool may not be allocated by the Team Leader to themselves. [ Clause to confirm – retain or remove. ]

**3.6 When Commission Is Earned and Paid**

All commission, personal and override alike, is earned on collection, not on signature. A transaction enters the commission calculation only once the Company has actually received the commission due to it. Commission earned in a given month is paid on the 15th day of the following month.

Where a transaction is cancelled, rescinded or refunded before the Company's commission has been fully collected, no entitlement to commission arises in respect of that transaction, and any amount already paid in respect of it is set off against future commission entitlements.

**3.7 Transport & Fuel**

[ To confirm: fixed monthly transport allowance, or the same performance-tiered inspection-log reimbursement applied to Sales Consultants. ]

## 4. Working Hours

{{work_days}} days per week, {{work_hours}}. Rest day(s): {{weekend}}. [ Weekend or site-visit obligations falling outside these hours – to confirm. ]

## 5. Confidentiality & Non-Solicitation

[ Scope to confirm: client database, pricing, developer terms, and non-solicitation of Company staff and clients for a defined period following departure. ]

## 6. Acknowledgment

By signing below, the Employee confirms having read and understood the amended terms set out in this letter, and accepts the position of Sales Team Leader on those terms.

**The Employee**

Name: {{employee_name}}    Signature: ______________________    Date: ______________

**For and on behalf of the Company**

Name: ______________________    Signature: ______________________    Date: ______________

Company stamp
$t$);
  end if;

  /* ---------------- Job descriptions (sections 1-2 of each contract) ---------------- */
  if r_junior is not null and not exists (select 1 from public.job_templates where title = 'Job Description – Junior Sales Consultant') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_junior, 'jd', 'en', 'Job Description – Junior Sales Consultant',
$t$# JOB DESCRIPTION – Sales Consultant (Junior)

**{{company_name}}**
{{company_address}}

| | |
|---|---|
| **Position** | {{position}} |
| **Department** | {{department}} |
| **Reports to** | {{reports_to}} |
| **Location** | {{location}} |
| **Employment type** | {{employment_type}} |
| **Working hours** | {{work_days}} days per week, {{work_hours}}; rest day(s): {{weekend}} |

## 1. Role Purpose

To generate, qualify and convert buyer and tenant enquiries into completed transactions across Home Vacation's off-plan, resale and rental portfolio, and to grow the Company's inventory by sourcing new units for sale and rent, while maintaining accurate records in the Company CRM at every stage.

## 2. Key Responsibilities

**Sales & Conversion**

- Respond to all assigned leads within the Company's stated response time and log every client contact in the CRM the same day.
- Conduct property inspections and site visits with clients.
- Present projects, payment plans and contract terms accurately, using only Company-approved materials and pricing.
- Negotiate and close transactions and hand complete, signed documentation to Administration.

**Inventory & Lead Generation**

- Source new units (sale and rental) from owners and developers and register them with the Company.
- Generate leads through referrals, networking and follow-up on the existing database.

**Reporting & Compliance**

- Submit the daily activity report and weekly pipeline update. Any activity not recorded in writing is treated as not having taken place.
- Give no pricing, discount, payment-plan or delivery commitment to any client without the prior written approval of the Sales Team Leader.

## 3. Performance Measures

- Monthly sales target (sales and rentals), set in writing before each month.
- Leads answered within the stated response time and logged in the CRM the same day.
- Inspections conducted and recorded in the approved inspection log.
- Units sourced and registered in the CRM.
- Daily activity report and weekly pipeline update submitted on time.

## 4. Lead & Listing Ownership

The CRM is the sole record of ownership. Leads and units must be registered through Marketing before being worked; the earlier CRM timestamp prevails in any dispute. Walk-in and Company-generated clients belong to the Company and are assigned by Marketing.

Acknowledged by: {{employee_name}}    Signature: ______________________    Date: ______________
$t$);
  end if;

  if r_senior is not null and not exists (select 1 from public.job_templates where title = 'Job Description – Senior Sales Consultant') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_senior, 'jd', 'en', 'Job Description – Senior Sales Consultant',
$t$# JOB DESCRIPTION – Sales Consultant (Senior)

**{{company_name}}**
{{company_address}}

| | |
|---|---|
| **Position** | {{position}} |
| **Department** | {{department}} |
| **Reports to** | {{reports_to}} |
| **Location** | {{location}} |
| **Employment type** | {{employment_type}} |
| **Working hours** | {{work_days}} days per week, {{work_hours}}; rest day(s): {{weekend}} |

## 1. Role Purpose

To independently generate, qualify and close buyer and tenant transactions across Home Vacation's off-plan, resale and rental portfolio, and to grow the Company's inventory by sourcing new units for sale and rent. As an experienced consultant, the Senior Sales Consultant manages the full sales cycle without support, sets a professional example for junior colleagues, and maintains accurate records in the Company CRM at every stage.

## 2. Key Responsibilities

**Sales & Conversion**

- Independently manage the full sales cycle, from first contact to signed contract and handover, without requiring closing support.
- Respond to all assigned leads within the Company's stated response time and log every client contact in the CRM the same day.
- Conduct property inspections and site visits with clients.
- Present projects, payment plans and contract terms accurately, using only Company-approved materials and pricing.
- Negotiate and close transactions and hand complete, signed documentation to Administration.

**Inventory & Lead Generation**

- Source new units (sale and rental) from owners and developers and register them with the Company.
- Generate leads through referrals, networking, farming and follow-up on the existing database.

**Experience & Standards**

- Apply established market knowledge and negotiation experience to close deals efficiently and protect the Company's margins.
- Support and set an example for junior colleagues where requested by the Sales Team Leader.

**Reporting & Compliance**

- Submit the daily activity report and weekly pipeline update. Any activity not recorded in writing is treated as not having taken place.
- Give no pricing, discount, payment-plan or delivery commitment to any client without the prior written approval of the Sales Team Leader.

## 3. Performance Measures

- Monthly sales target (sales and rentals), set in writing before each month, closed independently.
- Leads answered within the stated response time and logged in the CRM the same day.
- Inspections conducted and recorded in the approved inspection log.
- Units sourced (farming) and registered in the CRM.
- Daily activity report and weekly pipeline update submitted on time.

## 4. Lead & Listing Ownership

The CRM is the sole record of ownership. Leads and units must be registered through Marketing before being worked; the earlier CRM timestamp prevails in any dispute. Walk-in and Company-generated clients belong to the Company and are assigned by Marketing.

Acknowledged by: {{employee_name}}    Signature: ______________________    Date: ______________
$t$);
  end if;

  if r_lead is not null and not exists (select 1 from public.job_templates where title = 'Job Description – Sales Team Leader') then
    insert into public.job_templates (role_id, doc_kind, language, title, body_md) values (r_lead, 'jd', 'en', 'Job Description – Sales Team Leader',
$t$# JOB DESCRIPTION – Sales Team Leader

**{{company_name}}**
{{company_address}}

| | |
|---|---|
| **Position** | {{position}} |
| **Department** | {{department}} |
| **Reports to** | {{reports_to}} |
| **Direct reports** | {{direct_reports}} |
| **Location** | {{location}} |
| **Working hours** | {{work_days}} days per week, {{work_hours}}; rest day(s): {{weekend}} |

## 1. Role Purpose

To own the Sales Department's monthly result, converting the Company's leads and inventory into completed, collected transactions through a team of Sales Consultants, while personally carrying a sales target as a producing member of that team, and reporting on both in writing every week and every month.

## 2. Key Responsibilities

**Team result ownership**

- Deliver the monthly team sales target set by management in writing before the start of each month.
- Allocate the team target across individual consultants and communicate each consultant's individual target in writing before the month begins.
- Intervene on any consultant tracking below 50% of their individual target by mid-month, in writing, with a documented corrective plan.

**Personal production**

- Achieve a personal monthly sales target, set in writing by management as a defined number of transactions.
- Maintain the same CRM, reporting and approval discipline required of every Sales Consultant.

**Lead distribution & pipeline control**

- Distribute assigned leads among consultants and register every allocation in the CRM at the time it is made.
- Review the full team pipeline at least twice weekly; no assigned lead may sit without a logged contact beyond the stated response time.
- Enforce CRM discipline across the team and answer for the completeness of the team's records.

**Reporting (mandatory)**

- Weekly report every [ Saturday ] before [ 12:00 ]: leads received and distributed, contacts, inspections, offers, contracts signed, collections, and each consultant's progress against target.
- Monthly report by the 3rd working day of the following month: team and per-consultant achievement, personal achievement, closed transactions with collection status, lost deals with reasons, inventory added, and next month's plan.

**Approval & control**

- No pricing, discount, payment plan or delivery commitment outside the approved price list without prior written approval of [ management level – to confirm ].
- Approve consultant fuel and inspection logs before submission to Accounts.
- Walk-in clients belong to the Company and are distributed by the Marketing Department only.

**Team development**

- Onboard new consultants and confirm their competence on the portfolio, payment plans and CRM before they handle clients independently.
- Hold a documented one-to-one performance review with each consultant at least monthly.

## 3. Performance Measures

- Team sales target (sales and rentals) achieved monthly.
- Personal sales target achieved monthly.
- Weekly and monthly reports submitted on time in the approved format.
- Pipeline reviewed twice weekly; no lead left without contact beyond the response time.
- Monthly one-to-one review completed with every consultant.

Acknowledged by: {{employee_name}}    Signature: ______________________    Date: ______________
$t$);
  end if;
end $seed$;
