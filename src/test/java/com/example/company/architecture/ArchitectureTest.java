package com.example.company.architecture;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.fields;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.methods;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.library.Architectures;
import com.tngtech.archunit.library.GeneralCodingRules;
import org.springframework.scheduling.annotation.Scheduled;

/**
 * Architecture rules enforced as tests. They currently match a near-empty codebase (see {@code archunit.properties},
 * which permits empty matches) and start enforcing as soon as the corresponding packages gain classes.
 */
@AnalyzeClasses(
        packages = "com.example.company",
        importOptions = {ImportOption.DoNotIncludeTests.class})
class ArchitectureTest {

    @ArchTest
    static final ArchRule layersAreRespected = Architectures.layeredArchitecture()
            .consideringOnlyDependenciesInLayers()
            // Optional layers so the empty starter scaffold passes; they enforce once packages gain classes.
            .optionalLayer("Controller")
            .definedBy("..controller..")
            .optionalLayer("Job")
            .definedBy("..job..")
            .optionalLayer("Service")
            .definedBy("..service..")
            .optionalLayer("Repository")
            .definedBy("..repository..")
            .whereLayer("Controller")
            .mayNotBeAccessedByAnyLayer()
            .whereLayer("Job")
            .mayNotBeAccessedByAnyLayer()
            .whereLayer("Service")
            .mayOnlyBeAccessedByLayers("Controller", "Job")
            .whereLayer("Repository")
            .mayOnlyBeAccessedByLayers("Service");

    @ArchTest
    static final ArchRule noFieldInjection = fields().should()
            .notBeAnnotatedWith("org.springframework.beans.factory.annotation.Autowired")
            .as("prefer constructor injection over field injection");

    /** Schedulers live in one place so their cron expressions and overlap rules can be reviewed together. */
    @ArchTest
    static final ArchRule scheduledMethodsLiveInJobPackage = methods()
            .that()
            .areAnnotatedWith(Scheduled.class)
            .should()
            .beDeclaredInClassesThat()
            .resideInAPackage("..job..");

    @ArchTest
    static final ArchRule noStandardStreams = GeneralCodingRules.NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS;

    @ArchTest
    static final ArchRule noJavaUtilLogging = GeneralCodingRules.NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING;

    @ArchTest
    static final ArchRule controllersAreNamedProperly = classes()
            .that()
            .resideInAPackage("..controller..")
            .and()
            .areNotAnonymousClasses()
            .and()
            .areTopLevelClasses()
            .should()
            .haveSimpleNameEndingWith("Controller");

    @ArchTest
    static final ArchRule servicesAreNamedProperly = classes()
            .that()
            .resideInAPackage("..service..")
            .and()
            .areAnnotatedWith("org.springframework.stereotype.Service")
            .should()
            .haveSimpleNameEndingWith("Service");

    @ArchTest
    static final ArchRule repositoriesAreNamedProperly = classes()
            .that()
            .resideInAPackage("..repository..")
            .and()
            .areTopLevelClasses()
            .should()
            .haveSimpleNameEndingWith("Repository");

    @ArchTest
    static final ArchRule jobsAreNamedProperly = classes()
            .that()
            .resideInAPackage("..job..")
            .and()
            .areTopLevelClasses()
            .should()
            .haveSimpleNameEndingWith("Scheduler");
}
