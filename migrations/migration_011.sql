-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_011.sql
-- Arabic text fields for job roles so the built-in (free, offline)
-- document engine can produce proper Arabic job descriptions and offers
-- without any external AI service. Seeds Arabic for the seven roles.
--
-- ADDITIVE ONLY. Run once, after 010.
-- =====================================================================

alter table public.job_roles add column if not exists duties_ar        text;
alter table public.job_roles add column if not exists requirements_ar  text;
alter table public.job_roles add column if not exists schedule_note_ar text;

update public.job_roles set schedule_note_ar = '6 أيام أسبوعياً، الجمعة إجازة'
 where schedule_note_ar is null and schedule_note ilike '6 days%friday off%';
update public.job_roles set schedule_note_ar = '5 أيام أسبوعياً، الجمعة والسبت إجازة'
 where schedule_note_ar is null and schedule_note ilike '5 days%';

update public.job_roles set
  duties_ar = 'استقبال العملاء المحتملين وتأهيلهم في نظام إنجاز CRM؛ تنسيق وحضور معاينات العملاء بتوجيه من الزملاء الأقدم؛ الإلمام بمحفظة مشروعات الغردقة ومكادي؛ إعداد عروض تقديمية للوحدات العقارية؛ متابعة العملاء المحتملين هاتفياً وعبر واتساب؛ تسجيل كل مشوار ومعاينة في نظام الموارد البشرية؛ تحقيق المستهدفات الشهرية للمستوى المبتدئ',
  requirements_ar = 'خبرة من صفر إلى سنتين في المبيعات (يفضل العقارية)؛ مهارات تواصل قوية بالعربية وإلمام أساسي بالإنجليزية؛ مظهر لائق ورغبة حقيقية في التعلم؛ إجادة استخدام تطبيقات الهاتف وأنظمة CRM؛ يفضل حاملي رخصة القيادة'
 where title_en = 'Junior Sales Representative' and duties_ar is null;

update public.job_roles set
  duties_ar = 'إدارة دورة البيع الكاملة للوحدات السكنية والسياحية عالية القيمة؛ التعامل مع العملاء الجادين بما فيهم العملاء الأجانب؛ التفاوض وإغلاق الصفقات المعقدة؛ إدارة خط مبيعات شخصي في نظام إنجاز CRM؛ توجيه مندوبي المبيعات المبتدئين في المعاينات وأساليب الإغلاق؛ تقديم رؤى عن أسعار السوق في الغردقة ومكادي؛ تحقيق المستهدفات الشهرية للمستوى الأول',
  requirements_ar = 'خبرة 3 سنوات فأكثر في المبيعات العقارية مع سجل مثبت في إغلاق الصفقات؛ إجادة العربية وإنجليزية عملية (الروسية أو الألمانية ميزة قوية للعملاء الأجانب)؛ مفاوض واثق؛ رخصة قيادة سارية'
 where title_en = 'Senior Sales Representative' and duties_ar is null;

update public.job_roles set
  duties_ar = 'قيادة فريق من مندوبي المبيعات؛ وضع المستهدفات الشهرية ومتابعتها؛ تدريب الفريق على المعاينات وأساليب الإغلاق؛ مراجعة لوحة متصدري الفريق؛ اعتماد حضور وإجازات أعضاء الفريق؛ رفع تقارير أسبوعية عن خط المبيعات والنتائج إلى الإدارة',
  requirements_ar = 'خبرة 3 سنوات فأكثر في المبيعات العقارية منها سنة على الأقل في قيادة فريق؛ انضباط قوي في استخدام نظام إنجاز CRM'
 where title_en = 'Sales Team Leader' and duties_ar is null;

update public.job_roles set
  duties_ar = 'مسك الدفاتر والقيود اليومية؛ متابعة مدفوعات العملاء والمستحقات؛ فواتير الموردين؛ التسويات البنكية؛ دعم إعداد الرواتب؛ الإقرارات الضريبية المصرية (ضريبة الدخل وضريبة القيمة المضافة) وأوراق التأمينات الاجتماعية بالتنسيق مع محاسب الشركة',
  requirements_ar = 'بكالوريوس تجارة قسم محاسبة؛ خبرة سنتين فأكثر؛ إجادة Excel؛ إلمام بإجراءات الضرائب والتأمينات الاجتماعية المصرية'
 where title_en = 'Accountant' and duties_ar is null;

update public.job_roles set
  duties_ar = 'إدارة العمل اليومي للمكتب؛ حفظ المستندات وأرشفتها؛ إعداد العقود؛ متابعة الأوراق الحكومية؛ الرد على الهاتف والاستقبال؛ تنظيم المواعيد؛ دعم إدارة الموارد البشرية في ملفات الموظفين',
  requirements_ar = 'شخصية منظمة؛ كتابة عربية جيدة؛ إنجليزية أساسية؛ مهارات جيدة في الحاسب الآلي (Word وExcel)'
 where title_en = 'Admin Officer' and duties_ar is null;

update public.job_roles set
  duties_ar = 'إدخال وتحديث بيانات الوحدات العقارية من صور وأسعار وأوصاف بالعربية والإنجليزية؛ النشر على البوابات العقارية وصفحات التواصل الاجتماعي؛ الحفاظ على دقة سجلات نظام إنجاز CRM وتحديثها؛ التعديل الأساسي للصور',
  requirements_ar = 'كتابة سريعة ودقيقة بالعربية والإنجليزية؛ اهتمام بالتفاصيل؛ إلمام بالبوابات العقارية ووسائل التواصل الاجتماعي'
 where title_en = 'Marketing Data Entry' and duties_ar is null;

update public.job_roles set
  duties_ar = 'صيانة الوحدات التي تديرها الشركة من أعمال السباكة والكهرباء والتكييف الأساسية؛ الاستجابة لطلبات صيانة المستأجرين والملاك؛ الفحص الدوري للوحدات؛ التنسيق مع الفنيين الخارجيين؛ متابعة قطع الغيار؛ تسجيل كل مشوار في نظام الموارد البشرية',
  requirements_ar = 'خبرة مثبتة في أعمال الصيانة؛ إلمام بالأدوات الأساسية؛ يفضل حاملي رخصة القيادة'
 where title_en = 'Maintenance Employee' and duties_ar is null;
