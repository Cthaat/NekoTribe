const sections=['acceptance','accounts','conduct','termination'];
const text=(value,path)=>{
  if(typeof value!=='string' || !value.isWellFormed() || !value.trim() || Buffer.byteLength(value,'utf8')>65536) throw new Error(`Invalid public terms text: ${path}`);
  return value;
};

/** Extract only text already displayed on the public terms page; this is not a retrieval index. */
export function buildPublicTermsCatalog(locales) {
  const documents=[];
  for(const locale of ['zh','en']) {
    const terms=locales?.[locale]?.auth?.terms?.sections;
    if(!terms || typeof terms!=='object') throw new Error(`Missing terms: ${locale}`);
    for(const section of sections) {
      const value=terms[section];
      const title=text(value?.title,`${locale}.${section}.title`);
      const blocks=[text(value?.content,`${locale}.${section}.content`)];
      if(section==='conduct') {
        blocks.push(text(value?.alertTitle,`${locale}.${section}.alertTitle`));
        for(const item of ['item1','item2','item3']) blocks.push(text(value?.prohibited?.[item],`${locale}.${section}.${item}`));
      }
      documents.push({key:`terms.${section}`,locale,href:`/${locale}/auth/terms#${section}`,title,blocks});
    }
  }
  return {id:'AI-PUBLIC-TERMS-CATALOG',revision:1,source:'i18n/locales/{locale}.json#auth.terms.sections',documents};
}

export function checkPublicTermsPage(page) {
  for(const section of sections) {
    if(!page.includes(`id: '#${section}'`) || !page.includes(`auth.terms.sections.${section}.content`)) throw new Error(`Terms page structure changed: ${section}`);
  }
  for(const key of ['alertTitle','prohibited.item1','prohibited.item2','prohibited.item3']) {
    if(!page.includes(`auth.terms.sections.conduct.${key}`)) throw new Error(`Terms page structure changed: ${key}`);
  }
}
