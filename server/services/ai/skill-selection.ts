import type {ConversationPurpose} from './conversation-access';

type SkillId='knowledge-answer'|'writing-draft'|'group-brief'|'moderation-advice';
type ToolId='public_search'|'public_statistics';
type SkillDefinition={id:SkillId;version:1;purpose:ConversationPurpose;tools:readonly ToolId[]};
type Scope={actorId:number;purpose:ConversationPurpose;groupId:number|null};
export type SkillSelection=Scope & {id:SkillId;version:1;selection:'explicit'|'purpose-default';tools:ToolId[]};
const catalog:readonly SkillDefinition[]=[
  {id:'knowledge-answer',version:1,purpose:'knowledge',tools:['public_search']},
  {id:'writing-draft',version:1,purpose:'writing',tools:[]},
  {id:'group-brief',version:1,purpose:'group',tools:['public_search','public_statistics']},
  {id:'moderation-advice',version:1,purpose:'moderation',tools:['public_search']}
];
const unavailable=():never=>{throw new Error('SKILL_UNAVAILABLE')};

export function summarizeAISkills(flags: Readonly<Record<ConversationPurpose, boolean>>) {
  return catalog.map(({ id, purpose, version }) => ({
    id, purpose, version, enabled: flags[purpose],
    explicit_selection: true
  }));
}

/** Config comes from trusted server settings, never from a model or request body. */
export class SkillRegistry {
  private readonly enabled:ReadonlySet<SkillId>;
  constructor(enabled:unknown) {
    if(!Array.isArray(enabled) || enabled.some(value=>typeof value!=='string' || !catalog.some(skill=>skill.id===value)) || new Set(enabled).size!==enabled.length) unavailable();
    this.enabled=new Set(enabled as SkillId[]);
  }
  /** Public configuration snapshot; it grants no authority and omits unreleased skills. */
  userAvailability() {
    return {
      knowledge:this.enabled.has('knowledge-answer'),
      writing:this.enabled.has('writing-draft'),
      group:this.enabled.has('group-brief'),
      moderation:this.enabled.has('moderation-advice')
    };
  }
  /** The callback must check current backend identity and scope; snapshots grant no authority. */
  async select(input:{actorId:number;purpose:ConversationPurpose;groupId:number|null;skillId:string|null},authorize:(scope:Scope)=>Promise<boolean>):Promise<SkillSelection> {
    if(!input || !Number.isSafeInteger(input.actorId) || input.actorId<1 || input.actorId>9_007_199_254_740_991 || !catalog.some(skill=>skill.purpose===input.purpose) ||
      (input.purpose==='group' ? !Number.isSafeInteger(input.groupId) || input.groupId===null || input.groupId<1 || input.groupId>999_999_999_999_999 : input.groupId!==null) ||
      (input.skillId!==null && (typeof input.skillId!=='string' || !input.skillId))) unavailable();
    const selected=catalog.find(skill=>input.skillId===null?skill.purpose===input.purpose:skill.id===input.skillId);
    if(!selected || selected.purpose!==input.purpose || !this.enabled.has(selected.id)) return unavailable();
    const scope:Scope={actorId:input.actorId,purpose:input.purpose,groupId:input.groupId};
    let allowed=false;try {allowed=(await authorize({...scope}))===true} catch {return unavailable()}
    if(!allowed) return unavailable();
    return {...scope,id:selected.id,version:selected.version,selection:input.skillId===null?'purpose-default':'explicit',tools:[...selected.tools]};
  }
}
