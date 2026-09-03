/* Test suite for the built-in job-description / offer-letter engine.
   Extracts the engine straight out of index.html (between the JD-ENGINE
   markers) so it always tests exactly what ships. Run: node tests/jd_engine.test.js */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const start = html.indexOf('/* JD-ENGINE-START */');
const end = html.indexOf('/* JD-ENGINE-END */');
if (start < 0 || end < 0) throw new Error('JD engine markers not found in index.html');
const src = html.slice(start, end);
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(src + '\nthis.JD = JD;', sandbox);
const JD = sandbox.JD;

const roles = require(path.join(__dirname, 'fixtures', 'job_roles.json'));
const company = { name_en: 'Home Vacation', name_ar: 'هوم فاكيشن', city: 'Hurghada', country: 'Egypt' };

const AR = /[؀-ۿ]/;
const LATIN_WORD = /\b[A-Za-z]{4,}\b/;
let pass = 0, fail = 0;
const failures = [];
const check = (name, cond, detail) => { if (cond) pass++; else { fail++; failures.push(name + (detail ? ' -> ' + detail : '')); } };

const customs = [null, 'Works 5 days per week, Friday and Saturday off; Salary 12,000 EGP net; Company car provided', 'يعمل 5 أيام أسبوعياً، الجمعة والسبت إجازة؛ الراتب 12,000 جنيه صافي'];
let docs = 0;
for (const role of roles) {
  for (const kind of ['jd', 'offer']) {
    for (const language of ['ar', 'en', 'both']) {
      for (const custom of customs) {
        for (const candidate of kind === 'offer' ? ['', 'Ahmed Mohamed Ali'] : ['']) {
          const md = JD.build({ role, kind, language, candidate_name: candidate, custom_notes: custom, company, weekendDays: [5, 6], today: '2026-09-03' });
          docs++;
          const tag = `${role.title_en}/${kind}/${language}/${custom ? 'custom' : 'plain'}${candidate ? '/named' : ''}`;
          check(tag + ' non-empty', md.length > 800, md.length);
          check(tag + ' no undefined/null', !/undefined|\bnull\b|\[object|NaN/.test(md));
          check(tag + ' no empty bullets', !/^- *$/m.test(md));
          check(tag + ' starts with H1', md.startsWith('# '));
          check(tag + ' title present', md.includes(role.title_en) || md.includes(role.title_ar));
          check(tag + ' papers count', (md.match(/^- /gm) || []).length >= (role.papers || []).length);
          if (language !== 'en') for (const p of role.papers || []) check(tag + ' paper listed (ar)', md.includes(p), p);
          if (language !== 'ar') check(tag + ' papers rendered in english', /National ID card|Birth certificate/.test(md));
          if (kind === 'jd') {
            check(tag + ' has responsibilities', /Key Responsibilities|المهام والمسؤوليات/.test(md));
            check(tag + ' has KPIs', /Key Performance Indicators|مؤشرات الأداء/.test(md));
            check(tag + ' has law leave rule', /21/.test(md) && /30/.test(md));
            check(tag + ' 48h rule', /48/.test(md));
          } else {
            check(tag + ' has terms', /Terms of Employment|شروط التعيين/.test(md));
            check(tag + ' probation 3 months', /3 months|3 أشهر/.test(md));
            check(tag + ' validity 7 days', /7 days|7 أيام/.test(md));
            check(tag + ' signature block', /Signature|التوقيع/.test(md));
            check(tag + ' reference no', /HV-OFR-20260903/.test(md));
            if (candidate) check(tag + ' candidate named', md.includes(candidate));
            else check(tag + ' blank name line', /______/.test(md));
          }
          if (custom) {
            check(tag + ' custom section', /Special Terms|شروط خاصة/.test(md));
            check(tag + ' custom text present', md.includes('12,000'));
          } else {
            check(tag + ' no custom section', !/Special Terms|شروط خاصة/.test(md));
          }
          // custom terms are the user's own words and appear verbatim in every version by design
          const stripUser = (s) => s.split('\n').filter((l) => !(custom && JD.items(custom).some((ci) => l.includes(ci))) && !l.includes('HV-OFR') && !(candidate && l.includes(candidate))).join('\n');
          if (language === 'ar') {
            check(tag + ' arabic present', AR.test(md));
            const lines = stripUser(md).split('\n').filter((l) => l.trim() && !/Engaz|CRM|Excel|Word|WhatsApp|VAT/.test(l));
            const leaks = lines.filter((l) => !AR.test(l) && LATIN_WORD.test(l));
            check(tag + ' arabic doc has no english-only lines', leaks.length === 0, leaks.slice(0, 2).join(' | '));
          }
          if (language === 'en') check(tag + ' english doc has no arabic', !AR.test(stripUser(md).replace(/هوم فاكيشن/g, '')));
          if (language === 'both') check(tag + ' both has separator', md.includes('\n---\n') && AR.test(md) && /Job (Description|Offer)/.test(md));
          check(tag + ' headings well-formed', md.split('\n').filter((l) => l.startsWith('#')).every((l) => /^#{1,3} \S/.test(l)));
        }
      }
    }
  }
}

/* edge cases */
const bare = { title_en: 'Driver', title_ar: 'سائق', papers: [] };
for (const kind of ['jd', 'offer']) for (const language of ['ar', 'en', 'both']) {
  const md = JD.build({ role: bare, kind, language, company, weekendDays: [5] });
  docs++;
  check(`bare/${kind}/${language} builds`, md.length > 400 && !/undefined|null/.test(md));
  check(`bare/${kind}/${language} default schedule`, /6 days per week, Friday off|6 أيام أسبوعياً، الجمعة إجازة/.test(md));
  check(`bare/${kind}/${language} salary fallback`, /salary scale|هيكل الأجور/.test(md));
}
check('items splits semicolons', JD.items('alpha; beta؛ gamma').length === 3);
check('items splits sentences', JD.items('Do this. Then that. Finally more').length === 3);
check('items drops numbering', JD.items('1. first\n2. second')[0] === 'first');
check('items keeps decimals', JD.items('Salary 12,000 EGP net').length === 1);

console.log(`documents generated: ${docs}`);
console.log(`checks: ${pass + fail} | passed: ${pass} | failed: ${fail}`);
if (failures.length) { console.log('FAILURES:'); failures.slice(0, 25).forEach((f) => console.log('  - ' + f)); }
fs.writeFileSync(path.join(__dirname, 'fixtures', 'sample_jd_ar.md'), JD.build({ role: roles.find((r) => /Senior/.test(r.title_en)), kind: 'jd', language: 'ar', company, weekendDays: [5, 6], today: '2026-09-03' }));
fs.writeFileSync(path.join(__dirname, 'fixtures', 'sample_offer_en.md'), JD.build({ role: roles.find((r) => /Accountant/.test(r.title_en)), kind: 'offer', language: 'en', candidate_name: 'Ahmed Mohamed Ali', custom_notes: 'Works 5 days per week, Friday and Saturday off; Basic salary 12,000 EGP; Company laptop provided', company, weekendDays: [5, 6], today: '2026-09-03' }));
process.exit(fail ? 1 : 0);
